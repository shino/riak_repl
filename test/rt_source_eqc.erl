-module(rt_source_eqc).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").
-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

-define(SINK_PORT, 5007).

-record(state, {
    remotes_available = ["a", "b", "c", "d", "e"],
    sources = [] % {remote_name(), {source_pid(), sink_pid(), [object_to_ack()]}}
    }).

prop_test_() ->
    {timeout, 30, fun() ->
        ?assert(eqc:quickcheck(?MODULE:prop_main()))
    end}.

prop_main() ->
    ?FORALL(Cmds, commands(?MODULE),
        aggregate(command_names(Cmds), begin
            {H, S, Res} = run_commands(?MODULE, Cmds),
            process_flag(trap_exit, false),
            pretty_commands(?MODULE, Cmds, {H,S,Res}, Res == ok)
        end)).

%% ====================================================================
%% Generators (including commands)
%% ====================================================================

command(S) ->
    ?debugMsg("Narn"),
    oneof(
        [{call, ?MODULE, connect_to_v1, [remote_name(S)]} || S#state.remotes_available /= []] ++
        [{call, ?MODULE, connect_to_v2, [remote_name(S)]} || S#state.remotes_available /= []] ++
        [{call, ?MODULE, disconnect, [elements(S#state.sources)]} || S#state.sources /= []] ++
        % push an object that may already have been rt'ed
        [{call, ?MODULE, push_object, [g_unique_remotes()]}] ++
        [{call, ?MODULE, ack_object, [elements(S#state.sources)]} || S#state.sources /= []]
    ).

g_unique_remotes() ->
    ?LET(Remotes, list(g_remote_name()), lists:usort(Remotes)).

g_remote_name() ->
    oneof(["a", "b", "c", "d", "e"]).

% name of a remote
remote_name(#state{remotes_available = []}) ->
    erlang:error(no_name_available);
remote_name(#state{remotes_available = Remotes}) ->
    oneof(Remotes).

precondition(S, {call, disconnect, _Args}) ->
    S#state.sources /= [];
precondition(S, {call, ack_object, _Args}) ->
    S#state.sources /= [];
precondition(_S, _Call) ->
    true.

%% ====================================================================
%% state generation
%% ====================================================================

initial_state() ->
    process_flag(trap_exit, true),
    ?debugFmt("I am the lizard queen! ~p", [self()]),
    abstract_gen_tcp(),
    abstract_stats(),
    abstract_stateful(),
    abstract_connection_mgr(),
    {ok, _RTPid} = start_rt(),
    {ok, _RTQPid} = start_rtq(),
    {ok, _TCPMonPid} = start_tcp_mon(),
    {ok, _FakeSinkPid} = start_fake_sink(),
    #state{}.

next_state(S, Res, {call, _, connect_to_v1, [Remote]}) ->
    next_state_connect(decode_res_connect_v1, Remote, Res, S);

next_state(S, Res, {call, _, connect_to_v2, [Remote]}) ->
    next_state_connect(decode_res_connect_v2, Remote, Res, S);

next_state(S, _Res, {call, _, disconnect, [Source]}) ->
    {Remote, _} = Source,
    Sources = lists:delete(Source, S#state.sources),
    S#state{sources = Sources, remotes_available = [Remote | S#state.remotes_available]};

next_state(S, Res, {call, _, push_object, [Remotes]}) ->
    Sources = update_unacked_objects(Remotes, Res, S#state.sources),
    S#state{sources = Sources};

next_state(S, _Res, {call, _, ack_object, [{Remote, _Source}]}) ->
    case lists:keytake(Remote, 1, S#state.sources) of
        false ->
            S;
        {value, {Remote, RealSource}, Sources} ->
            Updated = {Remote, {call, ?MODULE, model_ack_object, [RealSource]}},
            Sources2 = [Updated | Sources],
            S#state{sources = Sources2}
    end.

next_state_connect(DecodeFunc, Remote, Res, State) ->
    case lists:keyfind(Remote, 1, State#state.sources) of
        true ->
            State;
        false ->
            Entry = {Remote, {call, ?MODULE, DecodeFunc, [Remote, Res]}},
            Sources = [Entry | State#state.sources],
            Remotes = lists:delete(Remote, State#state.remotes_available),
            State#state{sources = Sources, remotes_available = Remotes}
    end.

decode_res_connect_v1(_Remote, Res) ->
    Res.

decode_res_connect_v2(_Remote, Res) ->
    Res.

update_unacked_objects(Remotes, Res, Sources) ->
    update_unacked_objects(Remotes, Res, Sources, []).

update_unacked_objects(_Remotes, _REs, [], Acc) ->
    lists:reverse(Acc);

update_unacked_objects(Remotes, Res, [{Remote, Source} = KV | Tail], Acc) ->
    case lists:member(Remote, Remotes) of
        true ->
            update_unacked_objects(Remotes, Res, Tail, [KV | Acc]);
        false ->
            Entry = {call, ?MODULE, model_push_object, [Res, Source]},
            update_unacked_objects(Remotes, Res, Tail, [{Remote, Entry} | Acc])
    end.

model_push_object(Res, {Source, Sink, ObjQueue}) ->
    {Source, Sink, ObjQueue ++ [Res]}.

model_ack_object({_Source, _Sink, []} = SourceState) ->
    SourceState;
model_ack_object({Source, Sink, [_Acked | Rest]}) ->
    {Source, Sink, Rest}.

%% ====================================================================
%% postcondition
%% ====================================================================

postcondition(_State, {call, _, connect_to_v1, [_RemoteName]}, {error, _}) ->
    false;
postcondition(_State, {call, _, connect_to_v1, [_RemoteName]}, Res) ->
    {Source, Sink, []} = Res,
    is_pid(Source) andalso is_pid(Sink);
postcondition(_S, _C, _R) ->
    true.

%% ====================================================================
%% test callbacks
%% ====================================================================

connect_to_v1(RemoteName) ->
    stateful:set(version, {realtime, {1,0}, {1,0}}),
    stateful:set(remote, RemoteName),
    {ok, SourcePid} = riak_repl2_rtsource_conn:start_link(RemoteName),
    receive
        {sink_started, SinkPid} ->
            {SourcePid, SinkPid, []}
    after 1000 ->
        {error, timeout}
    end.

connect_to_v2(RemoteName) ->
    stateful:set(version, {realtime, {2,0}, {2,0}}),
    stateful:set(remote, RemoteName),
    {ok, SourcePid} = riak_repl2_rtsource_conn:start_link(RemoteName),
    receive
        {sink_started, SinkPid} ->
            {SourcePid, SinkPid, []}
    after 1000 ->
        {error, timeout}
    end.

disconnect(ConnectState) ->
    {Remote, {Source, _Sink, _Objects}} = ConnectState,
    riak_repl2_rtsource_conn:stop(Source),
    Remote.

push_object(Remotes) ->
    BinObjects = term_to_binary([<<"der object">>]),
    Meta = [{routed_clusters, Remotes}],
    riak_repl2_rtq:push(1, BinObjects, Meta),
    {1, BinObjects, Meta}.

ack_object({_Remote, {_Source, _Sink, []}}) ->
    [];
ack_object(SourceState) ->
    {_Remote, {_Source, Sink, Objects}} = SourceState,
    Sink ! ack_object,
    [_Acked | Objects2] = Objects,
    Objects2.

%        [{call, ?MODULE, connect_to_v1, [remote_name()]}] ++
%        [{call, ?MODULE, connect_to_v2, [remote_name()]}] ++
%        [{call, ?MODULE, disconnect, [elements(S#state.sources)]} || S#state.sources /= []] ++
%        % push an object that may already have been rt'ed
%        [{call, ?MODULE, push_object, [g_unique_remotes()]}] ++
%        [{call, ?MODULE, ack_object, [elements(S#state.sources)]} || S#state.sources /= []]

%% ====================================================================
%% helpful utility functions
%% ====================================================================

abstract_gen_tcp() ->
    reset_meck(gen_tcp, [unstick, passthrough]),
    meck:expect(gen_tcp, setopts, fun(Socket, Opts) ->
        inet:setopts(Socket, Opts)
    end).

abstract_stats() ->
    reset_meck(riak_repl_stats),
    meck:expect(riak_repl_stats, rt_source_errors, fun() -> ok end),
    meck:expect(riak_repl_stats, objects_sent, fun() -> ok end).

abstract_stateful() ->
    reset_meck(stateful),
    meck:expect(stateful, set, fun(Key, Val) ->
        Fun = fun() -> Val end,
        meck:expect(stateful, Key, Fun)
    end),
    meck:expect(stateful, delete, fun(Key) ->
        meck:delete(stateful, Key, 0)
    end).

abstract_connection_mgr() ->
    reset_meck(riak_core_connection_mgr, [passthrough]),
    meck:expect(riak_core_connection_mgr, connect, fun(_ServiceAndRemote, ClientSpec) ->
        proc_lib:spawn_link(fun() ->
            Version = stateful:version(),
            {_Proto, {TcpOpts, Module, Pid}} = ClientSpec,
            {ok, Socket} = gen_tcp:connect("localhost", ?SINK_PORT, [binary | TcpOpts]),
            ok = Module:connected(Socket, gen_tcp, {"localhost", ?SINK_PORT}, Version, Pid, [])
        end),
        {ok, make_ref()}
    end).

start_rt() ->
    kill_and_wait(riak_repl2_rt),
    riak_repl2_rt:start_link().

start_rtq() ->
    kill_and_wait(riak_repl2_rtq),
    riak_repl2_rtq:start_link().

start_tcp_mon() ->
    kill_and_wait(riak_core_tcp_mon),
    riak_core_tcp_mon:start_link().

start_fake_sink() ->
    reset_meck(riak_core_service_mgr, [passthrough]),
    WhoToTell = self(),
    meck:expect(riak_core_service_mgr, register_service, fun(HostSpec, _Strategy) ->
        kill_and_wait(fake_sink),
        {_Proto, {TcpOpts, _Module, _StartCB, _CBArgs}} = HostSpec,
        sink_listener(TcpOpts, WhoToTell)
    end),
    riak_repl2_rtsink_conn:register_service().

sink_listener(TcpOpts, WhoToTell) ->
    TcpOpts2 = [binary, {reuseaddr, true} | TcpOpts],
    ?debugFmt("starting fake sink with opts ~p", [TcpOpts2]),
    Self = self(),
    Pid = proc_lib:spawn_link(fun() ->
        {ok, Listen} = gen_tcp:listen(?SINK_PORT, TcpOpts2),
        proc_lib:spawn(?MODULE, sink_acceptor, [Listen, WhoToTell]),
        receive
            _ -> ok
        end
    end),
    register(fake_sink, Pid),
    {ok, Pid}.

sink_acceptor(Listen, WhoToTell) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    Version = stateful:version(),
    Pid = proc_lib:spawn_link(?MODULE, fake_sink, [Socket, Version, undefined]),
    ok = gen_tcp:controlling_process(Socket, Pid),
    WhoToTell ! {sink_started, Pid},
    sink_acceptor(Listen, WhoToTell).

fake_sink(Socket, Version, LastData) ->
    receive
        stop ->
            ok;
        {'$gen_call', From, _Msg} ->
            gen_server:reply(From, {error, nyi}),
            fake_sink(Socket, Version, LastData);
        {tcp, Socket, Bin} ->
            fake_sink(Socket, Version, Bin);
        {tcp_error, Socket, Err} ->
            exit(Err);
        {tcp_closed, Socket} ->
            ok
    end.

reset_meck(Mod) ->
    reset_meck(Mod, []).

reset_meck(Mod, Opts) ->
    try meck:unload(Mod) of
        ok -> ok
    catch
        error:{not_mocked, Mod} -> ok
    end,
    meck:new(Mod, Opts).

kill_and_wait(undefined) ->
    ok;

kill_and_wait(Atom) when is_atom(Atom) ->
    ?debugFmt("looking up dude: ~p", [Atom]),
    kill_and_wait(whereis(Atom));

kill_and_wait(Pid) when is_pid(Pid) ->
    unlink(Pid),
    ?debugFmt("Murdering a soul: ~p", [Pid]),
    exit(Pid, stupify),
    Mon = erlang:monitor(process, Pid),
    receive
        {'DOWN', Mon, process, Pid, _Why} ->
            ok
    end.
