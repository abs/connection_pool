%
% (c) Rdio 2010
%

-module(connection_pool).
-behaviour(gen_server).

-import(error_logger, [error_msg/1, error_msg/2, info_msg/2]).

-export([start_link/2]).

-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-export([run/2, close/1]).

-export([handle_conn_loop_msg/3]).

-export([get_proc_name/1]).

-export([get_state/1, endpoint_details/1]).

-export([init_connection/1]).

-record(state, {name, pool, n = 0, borrowed}).

get_state(PoolName) ->
    gen_server:call(PoolName, get_state).

endpoint_details(Name = {_PoolType, PoolName}) ->
    TabName = get_proc_name(Name),
    ets:lookup_element(TabName, {endpoint_details, PoolName}, 2);

endpoint_details(PoolType) ->
    ets:tab2list(PoolType).

start_link(Name, Details) ->
    ProcName = get_proc_name(Name),
    case whereis(ProcName) of
        undefined ->
            gen_server:start_link({local, ProcName},
              ?MODULE, [Name, Details], []);
        Pid ->
            {ok, Pid}
    end.

get_proc_name({PoolType, PoolName}) ->
    L = lists:concat([PoolType, '.', PoolName]),
    try
        erlang:list_to_existing_atom(L)
    catch
        _:badarg -> erlang:list_to_atom(L)
    end.

init([Name = {_PoolType, PoolName}, EndpointDetails]) ->
    TabName = get_proc_name(Name), 
    ets:new(TabName, [named_table, protected]),
    ets:insert(TabName, {{endpoint_details, PoolName}, EndpointDetails}),
    State = #state{name = Name, pool = queue:new(), borrowed = dict:new()},
    {ok, spool_up(State)}.

spool_up(State = #state{name = Name = {PoolType, _PoolName}, n = N}) ->
    case N >= apply(PoolType, num_connections, []) of
        true ->
            State;
        false ->
            init_connection(Name),
            timer:sleep(5),
            spool_up(State#state{n = N + 1})
    end.

init_connection(Name = {PoolType, _PoolName}) ->
    Conn = {P, _M} = spawn_monitor(PoolType, initialize, [Name, fun conn_loop/1]),
    P ! {self(), on_connected, Conn}.

handle_call({assign_endpoint_details, Details = {_, _, _}}, _From,
  State = #state{name = Name = {_PoolType, PoolName},
                 pool = Pool, borrowed = Borrowed}) ->
    TabName = get_proc_name(Name),
    ets:insert(TabName, {{endpoint_details, PoolName}, Details}),
    [P ! {self(), reconnect} || {P, _M} <- queue:to_list(Pool)],
    NewBorrowed = dict:map(fun(_Conn, Pending) ->
        [reconnect_upon_return | Pending]
    end, Borrowed),
    {reply, ok, State#state{borrowed = NewBorrowed}};

handle_call(get_state, _From,
  State = #state{pool = P, borrowed = Borrowed}) ->
    {reply, [{total, State#state.n},
             {queue, queue:len(P)},
             {borrowed, dict:size(Borrowed)}], State};

handle_call(close, _From,
  State = #state{pool = P, borrowed = Borrowed}) ->
    lists:foreach(fun({Conn, MonitorRef}) ->
        erlang:demonitor(MonitorRef),
        Conn ! {self(), close}
    end, lists:append([dict:fetch_keys(Borrowed), queue:to_list(P)])),
    {reply, closed, State};

handle_call(borrow, _From,
  State = #state{pool = P, n = _N, borrowed = Borrowed}) ->
    case queue:out(P) of
        {{value, ConnRef}, NewPool} ->
            NewBorrowed = dict:store(ConnRef, [], Borrowed),
            {reply, ConnRef, State#state{pool = NewPool,
                                         borrowed = NewBorrowed}};
        {empty, P} ->
            {reply, {empty, dict:size(Borrowed)}, State}
    end.

handle_cast({give_back, Conn = {P, _M}},
  State = #state{pool = Pool, borrowed = Borrowed}) ->
    Pending = dict:fetch(Conn, Borrowed),
    case lists:member(reconnect_upon_return, Pending) of
        true ->
            P ! {self(), reconnect};
        false ->
            ok
    end,
    NewPool = queue:in(Conn, Pool),
    {noreply, State#state{pool = NewPool,
                          borrowed = dict:erase(Conn, Borrowed)}}.

handle_info({connected, Conn}, State = #state{name = PoolName, pool = Pool, n = _N}) ->
    info_msg("~p connected (queue:len(Pool) -> ~p)", [PoolName, queue:len(Pool)]),
    {noreply, State#state{pool = queue:in(Conn, Pool)}};

handle_info({'DOWN', MonitorRef, process, Pid, Info},
  State = #state{name = PoolName, pool = Pool, n = _N, borrowed = Borrowed}) ->
    error_msg("~p~n", [{connection_down, {Pid, MonitorRef}, PoolName, Info}]),
    CleanPool = queue:filter(fun
        ({_Pid, _MonitorRef}) -> false;
        (_) -> true
    end, Pool),
    erlang:send_after(1000 * 10, self(), {init_connection, PoolName}),
    NewBorrowed = dict:erase({Pid, MonitorRef}, Borrowed),
    {noreply, State#state{pool = CleanPool, borrowed = NewBorrowed}};

handle_info({init_connection, PoolName}, State) ->
    init_connection(PoolName),
    {noreply, State};

handle_info({'EXIT', _Pid, Reason}, State) ->
    {stop, Reason, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.

handle_conn_loop_msg(Loop, Msg, Details = {{PoolType, _PoolName}, Conn, ConnMonitorRef}) ->
    case Msg of
        {From, connection_please} ->
            From ! {connection, Conn},
            Loop(Details);
        {From, on_connected, C} ->
            From ! {connected, C},
            Loop(Details);
        {_From, close} ->
            PoolType:close({Conn, ConnMonitorRef}),    
            exit(close);
        {'DOWN', ConnMonitorRef, process, Conn, Info} ->
            exit({connection_exit, ConnMonitorRef, Conn, Info})
    end.

conn_loop(Details = {_Name, _Conn, _ConnMonitorRef}) ->
    receive Msg ->
        handle_conn_loop_msg(fun conn_loop/1, Msg, Details)
    end.

run(Name = {_PoolType, _PoolName}, F) ->
    ProcName = get_proc_name(Name),
    case gen_server:call(ProcName, borrow, 15000) of
        {empty, 0} ->
            % XXX this will choke the logger
            % info_msg("dead pool (~p~), ~p~n", [Name, F]),
            dead_endpoint;
        {empty, _BorrowedLen} ->
            % info_msg("empty pool (~p~), ~p~n", [Name, F]),
            timer:sleep(100),
            run(Name, F);
        ConnRef = {ConnPid, _MonitorRef} ->
            ConnPid ! {self(), connection_please},
            Conn = receive {connection, C} -> C end,
            try
                F(Conn)
            catch
                Y:Err ->
                    error_msg("connection_pool error: ~p", [{Name, Y, F, Err, erlang:get_stacktrace()}]),
                    throw(Err)
            after
                gen_server:cast(ProcName, {give_back, ConnRef})
            end
    end.

close(Pid) ->
    gen_server:call(Pid, close),
    exit(Pid, normal).

