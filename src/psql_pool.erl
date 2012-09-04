%
% (c) Rdio 2011
%

-module(psql_pool).

-export([initialize/2, close/1, num_connections/0,
         spec/1, spec/2]).

num_connections() -> 15.

spec(Module, {Name, Details}) ->
    {connection_pool:get_proc_name({Module, Name}),
      {connection_pool, start_link, [{Module, Name}, Details]},
      permanent, 2000, worker, case Module of ?MODULE -> []; _ -> [Module] end ++ [connection_pool, ?MODULE]}.

spec(Details) ->
    spec(?MODULE, Details).

connect(Name) ->
    {conn_opts, ConnOpts} = lists:keyfind(conn_opts, 1, connection_pool:endpoint_details(Name)),
    case apply(pgsql, connect, ConnOpts) of
        {ok, Conn} ->
            Conn;
        Err ->
            exit({pgsql, Err})
    end.

initialize(Name, Loop) ->
    Conn = connect(Name),
    true = link(Conn),
    Loop({Name, Conn}).

close(Conn) ->
    ok = pgsql:close(Conn).
