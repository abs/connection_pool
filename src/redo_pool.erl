-module(redo_pool).

-export([initialize/2, close/1,
         num_connections/0,
         spec/1, spec/2]).

-define(PING_INTERVAL, 290000). % 4 min 50 sec

num_connections() -> 5.

spec(Module, {Name, Details}) ->
    {connection_pool:get_proc_name({Module, Name}),
      {connection_pool, start_link, [{Module, Name}, Details]},
      permanent, 2000, worker, case Module of ?MODULE -> []; _ -> [Module] end ++ [connection_pool, ?MODULE]}.

spec(Details) ->
    spec(?MODULE, Details).

connect(Name) ->
    {conn_opts, ConnOpts} = lists:keyfind(conn_opts, 1, connection_pool:endpoint_details(Name)),
    {Host, Port} = ConnOpts,
    case redo:start_link(undefined, [{host, Host}, {port, Port}]) of
        {ok, Conn} ->
            Conn;
        Err ->
            exit({redo, Err})
    end.

initialize(Name) ->
    Conn = connect(Name),
    true = link(Conn),
    life_loop({Name, Conn}).

initialize(Name, _Loop) ->
    initialize(Name).

life_loop(Details = {Name, Conn}) ->
    receive Msg ->
        case Msg of
            {_From, reconnect} ->
                true = exit(Conn, normal),
                initialize(Name);
            _ ->
                connection_pool:handle_conn_loop_msg(fun life_loop/1,
                                                     Msg,
                                                     Details)
        end
    after ?PING_INTERVAL ->
        case redo:cmd(Conn, ["PING"]) of
            <<"PONG">> ->
                ok;
            {error, closed} ->
                exit(Conn, {error, closed})
        end,
        life_loop(Details)
    end.

close(Conn) ->
    exit(Conn, close).
