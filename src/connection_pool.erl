%
% (c) Rdio 2010
% (c) Connect.Me 2012
%

-module(connection_pool).
-behaviour(gen_server).

-export([start_link/2]).

-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-export([run/2, close/1]).

-export([handle_conn_loop_msg/3]).

-export([get_proc_name/1]).

-export([get_state/1, endpoint_details/1, report_dead_endpoint/1]).

-export([init_connection/1]).

-record(state, {name, pool, n = 0, borrowed, waiting, reconnect_throttle_ts = erlang:now()}).

get_state(PoolName) ->
    gen_server:call(PoolName, get_state).

report_dead_endpoint(Name = {_PoolType, _PoolName}) ->
    ProcName = get_proc_name(Name),
    gen_server:call(ProcName, reconnect).

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
    process_flag(trap_exit, true),
    State = #state{name = Name, pool = queue:new(), borrowed = dict:new(), waiting = queue:new()},
    {max_conns, MaxConns} = lists:keyfind(max_conns, 1, EndpointDetails),
    {ok, spool_up(State, MaxConns)}.

spool_up(State = #state{name = Name, n = N}, MaxConns) ->
    case N >= MaxConns of
        true ->
            State;
        false ->
            init_connection(Name),
            timer:sleep(5),
            spool_up(State#state{n = N + 1}, MaxConns)
    end.

init_connection(Name = {PoolType, _PoolName}) ->
    Conn = spawn_link(PoolType, initialize, [Name, fun conn_loop/1]),
    Conn ! {self(), on_connected, Conn}.

handle_call(get_state, _From,
  State = #state{pool = P, borrowed = Borrowed}) ->
    {reply, [{total, State#state.n},
             {queue, queue:len(P)},
             {borrowed, dict:size(Borrowed)}], State};

handle_call(reconnect, _From,
  State = #state{pool = P, borrowed = Borrowed}) ->
    lists:foreach(fun(Conn) ->
        Conn ! {self(), close}
    end, lists:append([dict:fetch_keys(Borrowed), queue:to_list(P)])),
    {reply, ok, State};

handle_call(close, _From,
  State = #state{pool = P, borrowed = Borrowed}) ->
    lists:foreach(fun(Conn) ->
        Conn ! {self(), close}
    end, lists:append([dict:fetch_keys(Borrowed), queue:to_list(P)])),
    {reply, closed, State};

handle_call(borrow, From,
  State = #state{pool = P, borrowed = Borrowed, waiting = Waiting}) ->
    case queue:out(P) of
        {{value, Conn}, NewPool} ->
            NewBorrowed = dict:store(Conn, [], Borrowed),
            {reply, Conn, State#state{pool = NewPool, borrowed = NewBorrowed}};
        {empty, P} ->
            case dict:size(Borrowed) of
                0 ->
                    {reply, {empty, dead_endpoint}, State};
                _ ->
                    {reply, {empty, wait}, State#state{waiting = queue:in(From, Waiting)}}
            end
    end.

handle_cast({give_back, Conn},
  State = #state{pool = Pool, borrowed = Borrowed, waiting = Waiting}) ->
    NewPool = queue:in(Conn, Pool),
    NewBorrowed = dict:erase(Conn, Borrowed),
    case queue:out(Waiting) of
        {{value, {Pid, Tag}}, NewWaiting} ->
            {{value, Conn0}, NewPool0} = queue:out(NewPool),
            NewBorrowed0 = case erlang:process_info(Pid, [current_function]) of
                undefined ->
                    NewBorrowed;
                _ ->
                    Pid ! {connection_wrapper, Tag, Conn0},
                    dict:store(Conn0, [{tag, Tag}], NewBorrowed)
            end,
            {noreply, State#state{pool = NewPool0, borrowed = NewBorrowed0, waiting = NewWaiting}};
        {empty, _} ->
            {noreply, State#state{pool = NewPool, borrowed = NewBorrowed}}
    end.

handle_info({connected, Conn}, State = #state{name = PoolName, pool = Pool, borrowed = Borrowed, n = N}) ->
    case (queue:len(Pool) + 1) + dict:size(Borrowed) of
        N -> error_logger:info_msg("~p: ~p connections at your service~n", [PoolName, N]);
        _ -> ok
    end,
    {noreply, State#state{pool = queue:in(Conn, Pool)}};

handle_info({'EXIT', Conn, _Reason},
  State = #state{name = PoolName,
                 pool = Pool,
                 n = _N,
                 borrowed = Borrowed,
                 reconnect_throttle_ts = ThrottleTs}) ->
    error_logger:error_msg("~p~n", [{connection_down, Conn, PoolName}]),
    CleanPool = queue:filter(fun
        (Conn0) when Conn0 =:= Conn -> false;
        (_) -> true
    end, Pool),
    Now = erlang:now(),
    Time = case timer:now_diff(Now, ThrottleTs) / 1000000 of Seconds when Seconds > 60 -> 0; _ -> 1000 * 10 end,
    true = is_reference(erlang:send_after(Time, self(), {init_connection, PoolName})),
    NewBorrowed = dict:erase(Conn, Borrowed),
    {noreply, State#state{pool = CleanPool, borrowed = NewBorrowed, reconnect_throttle_ts = erlang:now()}};

handle_info({init_connection, PoolName}, State) ->
    init_connection(PoolName),
    {noreply, State};

handle_info({_From, closed}, State) ->
    {noreply, State}.

terminate(Reason, #state{name = PoolName}) ->
    error_logger:info_msg("connection_pool ~p exiting with reason ~p~n", [{self(), PoolName}, Reason]),
    ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.

handle_conn_loop_msg(Loop, Msg, Details = {{PoolType, _PoolName}, Conn}) ->
    case Msg of
        {From, connection_please} ->
            From ! {connection, Conn},
            Loop(Details);
        {From, on_connected, C} ->
            From ! {connected, C},
            Loop(Details);
        {From, close} ->
            PoolType:close(Conn),
            From ! {self(), closed},
            exit(close);
        {'EXIT', Conn, Reason} ->
            exit({connection_exit, Conn, Reason})
    end.

conn_loop(Details = {_Name, _Conn}) ->
    receive Msg ->
        handle_conn_loop_msg(fun conn_loop/1, Msg, Details)
    end.

run(Name = {_PoolType, _PoolName}, F) ->
    ProcName = get_proc_name(Name),
    case gen_server:call(ProcName, borrow, 15000) of
        {empty, dead_endpoint} ->
            dead_endpoint;
        {empty, wait} ->
            receive
                {connection_wrapper, _Tag, ConnectionWrapper} ->
                    do_run(ConnectionWrapper, Name, ProcName, F)
            end;
        ConnectionWrapper ->
            do_run(ConnectionWrapper, Name, ProcName, F)
    end.

do_run(Connection, _Name, ProcName, F) ->
    Connection ! {self(), connection_please},
    Conn = receive {connection, C} -> C end,
    try
        Res = F(Conn),
        gen_server:cast(ProcName, {give_back, Connection}),
        Res
    catch
        _Y:Err ->
            error_logger:error_msg("~p~n", [erlang:get_stacktrace()]),
            Connection ! {self(), close},
            throw(Err)
    end.

close(Pid) ->
    gen_server:call(Pid, close),
    exit(Pid, normal).
