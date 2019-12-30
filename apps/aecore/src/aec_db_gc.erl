-module(aec_db_gc).

%% Implementation of Garbage Collection of Account state.
%% To run, the GC needs to be `enabled` (config param), and node synced.
%% If key block `interval` (config parameter) is hit, GC starts collecting
%% of the reachable nodes from most recent generations (`history` config parameter).
%%
%% If #data.enabled and #data.synced are true, #data.hashes indicates the GC status:
%% - undefined    - not the right time to run GC
%% - is pid       - we are scanning reachable nodes
%% - is reference - waiting for signal to execute the `swap_nodes` phase
%%
%% GC scan is performed on the background. The only synchronous part of GC is `swap_nodes` phase.
%% (initiated by aec_conductor on key block boundary)
%%
%% More details can be found here: https://github.com/aeternity/papers/blob/master/Garbage%20collector%20for%20account%20state%20data.pdf
%%
%% Note: if something goes wrong (for example, software bug in GC), a typical manifestation of
%% such issue is hitting of `hash_not_present_in_db` crashes.
%% In that case a full resync is needed.
%% Please don't delete the GC-ed database dir yet - rename it and inform us at forum.aeternity.com
%% or make a issue in https://github.com/aeternity/aeternity/issues so we can retrieve the DB and
%% look at it.

-behaviour(gen_statem).

%% API
-export([start_link/0,
         start_link/3,
         maybe_garbage_collect/0,
         maybe_swap_nodes/0,
         stop/0]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, terminate/3, code_change/4]).
-export([handle_event/4]).

-record(data,
        {enabled  :: boolean(),                         % do we garbage collect?
         interval :: non_neg_integer(),                 % how often (every `interval` blocks) GC runs
         history  :: non_neg_integer(),                 % how many block state back from top to keep
         synced   :: boolean(),                         % we only run GC if chain is synced
         height   :: undefined | non_neg_integer(),     % latest height of MPT hashes stored in tab
         hashes   :: undefined | pid() | reference()}). % hashes tab (or process filling the tab 1st time)

-include_lib("aecore/include/aec_db.hrl").

-define(DEFAULT_INTERVAL, 50000).
-define(DEFAULT_HISTORY, 500).
-define(GCED_TABLE_NAME, aec_account_state_gced).
-define(TABLE_NAME, aec_account_state).

-define(TIMED(Expr), timer:tc(fun () -> Expr end)).
-define(LOG(Fmt), lager:info(Fmt, [])).         % io:format(Fmt"~n")
-define(LOG(Fmt, Args), lager:info(Fmt, Args)). % io:format(Fmt"~n", Args)

%%%===================================================================
%%% API
%%%===================================================================

%% We don't support reconfiguration of config parameters when the GC is already up,
%% doesn't seem to have practical utility.
start_link() ->
    #{enabled := Enabled, interval := Interval, history := History} = config(),
    start_link(Enabled, Interval, History).

start_link(Enabled, Interval, History) ->
    gen_statem:start_link({local, ?MODULE}, ?MODULE, [Enabled, Interval, History], []).


%% To avoid starting of the GC process just for EUNIT
-ifdef(EUNIT).
maybe_garbage_collect() -> nop.
-else.

%% This should be called when there are no processes modifying the block state
%% (e.g. aec_conductor on specific places)
maybe_garbage_collect() ->
    gen_statem:call(?MODULE, maybe_garbage_collect).
-endif.

maybe_swap_nodes() ->
    maybe_swap_nodes(?GCED_TABLE_NAME, ?TABLE_NAME).

stop() ->
    gen_statem:stop(?MODULE).

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

%% Change of configuration parameters requires restart of the node.
init([Enabled, Interval, History])
  when is_integer(Interval), Interval > 0, is_integer(History), History > 0 ->
    if Enabled ->
            aec_events:subscribe(top_changed),
            aec_events:subscribe(chain_sync);
       true ->
            ok
    end,
    Data = #data{enabled  = Enabled,
                 interval = Interval,
                 history  = History,
                 synced   = false,
                 height   = undefined,
                 hashes   = undefined},
    {ok, idle, Data}.


%% once the chain is synced, there's no way to "unsync"
handle_event(info, {_, chain_sync, #{info := {chain_sync_done, _}}}, idle,
             #data{enabled = true} = Data) ->
    aec_events:unsubscribe(chain_sync),
    {keep_state, Data#data{synced = true}};

%% starting collection when the *interval* matches, and don't have a GC state (hashes = undefined)
handle_event(info, {_, top_changed, #{info := #{height := Height}}}, idle,
             #data{interval = Interval, history = History,
                   enabled = true, synced = true,
                   height = undefined, hashes = undefined} = Data)
  when Height rem Interval == 0 ->
    Parent = self(),
    Pid = spawn_link(
            fun () ->
                    FromHeight = max(Height - History, 0),
                    {Time, {ok, Hashes}} = ?TIMED(collect_reachable_hashes(FromHeight, Height)),
                    ets:give_away(Hashes, Parent, {{FromHeight, Height}, Time})
            end),
    {keep_state, Data#data{height = Height, hashes = Pid}};

%% received GC state from the phase above
handle_event(info, {'ETS-TRANSFER', Hashes, _, {{FromHeight, ToHeight}, Time}}, idle,
             #data{enabled = true, hashes = Pid} = Data)
  when is_pid(Pid) ->
    ?LOG("Scanning of ~p reachable hashes in range <~p, ~p> took ~p seconds",
         [ets:info(Hashes, size), FromHeight, ToHeight, Time / 1000000]),
    {next_state, ready, Data#data{hashes = Hashes}};

%% with valid GC state (reachable hashes in ETS cache), follow up on keeping that cache
%% synchronized with Merkle-Patricia Trie on disk keeping the latest changes in accounts
handle_event(info, {_, top_changed, #{info := #{block_type := key, height := Height}}}, ready,
             #data{enabled = true, synced = true, height = LastHeight, hashes = Hashes} = Data)
  when is_reference(Hashes) ->
    if Height > LastHeight ->
            {ok, _} = range_collect_reachable_hashes(Height, Data),
            {keep_state, Data#data{height = Height}};
       true ->
            %% in case previous key block was a fork, we can receive top_changed event
            %% with the same or lower height as seen last time
            {ok, _} = collect_reachable_hashes_delta(Height, Hashes),
            {keep_state, Data}
    end;

%% with valid GC state, if we are on key block boundary, we can
%% clear the table and insert reachable hashes back
handle_event({call, _From}, maybe_garbage_collect, ready,
             #data{enabled = true, synced = true, hashes = Hashes} = Data)
  when Hashes /= undefined, not is_pid(Hashes) ->
    Header = aec_chain:top_header(),
    case aec_headers:type(Header) of
        key ->
            Height  = aec_headers:height(Header),
            {ok, _} = range_collect_reachable_hashes(Height, Data),
            %% we exit here si GCEd table is swapped at startup
            store_cache_and_restart(Hashes, ?GCED_TABLE_NAME);
        micro ->
            {keep_state, Data}
    end;
handle_event({call, From}, maybe_garbage_collect, _, Data) ->
    {keep_state, Data, {reply, From, nop}};

handle_event(_, _, _, Data) ->
    {keep_state, Data}.


terminate(_Reason, _State, _Data) -> void.

code_change(_, State, Data, _) -> {ok, State, Data}.

callback_mode() -> handle_event_function.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% From - To (inclusive)
collect_reachable_hashes(FromHeight, ToHeight) when FromHeight < ToHeight ->
    {ok, Hashes} = collect_reachable_hashes_fullscan(FromHeight),     % table is created here
    {ok, Hashes} = range_collect_reachable_hashes(FromHeight, ToHeight, Hashes), % and reused
    {ok, Hashes}.

collect_reachable_hashes_fullscan(Height) ->
    Tab = ets:new(gc_reachable_hashes, [public]),
    MPT = get_mpt(Height),
    ?LOG("GC fullscan at height ~p of accounts with hash ~w",
         [Height, aeu_mp_trees:root_hash(MPT)]),
    {ok, aeu_mp_trees:visit_reachable_hashes(MPT, Tab, fun store_hash/3)}.

%% assumes Height - 1, Height - 2, ... down to Height - History
%% are in Hashes from previous runs
collect_reachable_hashes_delta(Height, Hashes) ->
    MPT = get_mpt(Height),
    ?LOG("GC diffscan at height ~p of accounts with hash ~w",
         [Height, aeu_mp_trees:root_hash(MPT)]),
    {ok, aeu_mp_trees:visit_reachable_hashes(MPT, Hashes, fun store_unseen_hash/3)}.

range_collect_reachable_hashes(ToHeight, #data{height = LastHeight, hashes = Hashes}) ->
    range_collect_reachable_hashes(LastHeight, ToHeight, Hashes).
range_collect_reachable_hashes(LastHeight, ToHeight, Hashes) ->
    [collect_reachable_hashes_delta(H, Hashes) || H <- lists:seq(LastHeight + 1, ToHeight)],
    {ok, Hashes}.

store_cache_and_restart(Hashes, GCedTab) ->
    {atomic, ok} = create_accounts_table(GCedTab),
    {ok, _Count} = store_cache(Hashes, GCedTab),
    supervisor:terminate_child(aec_conductor_sup, aec_conductor),
    init:restart(),
    sys:suspend(self(), infinity).

create_accounts_table(Name) ->
    Rec = ?TABLE_NAME,
    Fields = record_info(fields, ?TABLE_NAME),
    mnesia:create_table(Name, aec_db:tab(aec_db:backend_mode(), Rec, Fields, [{record_name, Rec}])).


iter(Fun, ets, Tab) ->
    ets:foldl(fun ({Hash, Node}, ok) -> Fun(Hash, Node), ok end, ok, Tab);
iter(Fun, mnesia, Tab) ->
    mnesia:foldl(fun (X, ok) -> Fun(element(2, X), element(3, X)), ok end, ok, Tab).


do_write_nodes(SrcMod, SrcTab, TgtTab) ->
    ?TIMED(aec_db:ensure_transaction(
             fun () ->
                     iter(fun (Hash, Node) ->
                                  aec_db:write_accounts_node(TgtTab, Hash, Node)
                          end, SrcMod, SrcTab)
             end, [], sync_transaction)).

store_cache(SrcHashes, TgtTab) ->
    NodesCount = ets:info(SrcHashes, size),
    ?LOG("Writing ~p reachable account nodes to table ~p ...", [NodesCount, TgtTab]),
    {WriteTime, ok} = do_write_nodes(ets, SrcHashes, TgtTab),
    ?LOG("Writing reachable account nodes took ~p seconds", [WriteTime / 1000000]),
    DBCount = length(mnesia:dirty_select(TgtTab, [{'_', [], [1]}])),
    ?LOG("GC cache has ~p aec_account_state records", [DBCount]),
    {ok, NodesCount}.

maybe_swap_nodes(SrcTab, TgtTab) ->
    try mnesia:dirty_first(SrcTab) of % table exists
        H when is_binary(H) ->        % and is non empty
            ?LOG("Clearing table ~p ...", [TgtTab]),
            {atomic, ok} = mnesia:clear_table(TgtTab),
            ?LOG("Writing garbage collected accounts ..."),
            {WriteTime, ok} = do_write_nodes(mnesia, SrcTab, TgtTab),
            ?LOG("Writing garbage collected accounts took ~p seconds", [WriteTime / 1000000]),
            DBCount = length(mnesia:dirty_select(TgtTab, [{'_', [], [1]}])),
            ?LOG("DB has ~p aec_account_state records", [DBCount]),
            ?LOG("Removing garbage collected table ~p ...", [?GCED_TABLE_NAME]),
            mnesia:delete_table(?GCED_TABLE_NAME),
            ok;
        '$end_of_table' ->
            ok
    catch
        exit:{aborted,{no_exists,[_]}} ->
            ok
    end.

-spec get_mpt(non_neg_integer()) -> aeu_mp_trees:tree().
get_mpt(Height) ->
    {ok, Hash0} = aec_chain_state:get_key_block_hash_at_height(Height),
    {ok, Trees} = aec_chain:get_block_state(Hash0),
    AccountTree = aec_trees:accounts(Trees),
    {ok, RootHash} = aec_accounts_trees:root_hash(AccountTree),
    {ok, DB}       = aec_accounts_trees:db(AccountTree),
    aeu_mp_trees:new(RootHash, DB).


store_hash(Hash, Node, Tab) ->
    ets:insert_new(Tab, {Hash, Node}),
    {continue, Tab}.
store_unseen_hash(Hash, Node, Tab) ->
    case ets:lookup(Tab, Hash) of
        [_] -> stop;
        []  -> store_hash(Hash, Node, Tab)
    end.

config() ->
    maps:from_list(
      [{binary_to_atom(Key, utf8),
        aeu_env:user_config([<<"chain">>, <<"garbage_collection">>, Key], Default)} ||
          {Key, Default} <- [{<<"enabled">>, false},
                             {<<"interval">>, ?DEFAULT_INTERVAL},
                             {<<"history">>, ?DEFAULT_HISTORY}]]).


%% %%%% !!!!!!!!!!
%% log(Fmt, Args) ->
%%     file:write_file("/tmp/test.log", io_lib:format(Fmt, Args), [append]).
