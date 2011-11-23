%
% (c) Rdio 2011
%

-module(mysql_pool).

-export([initialize/2,
         num_connections/0,
         spec/1, spec/2]).

-define(PING_INTERVAL, 50000).

num_connections() -> 15.

atom_to_host('') -> "127.0.0.1";
atom_to_host(Host) -> atom_to_list(Host).

atom_to_port('') -> 3306;
atom_to_port(Port) -> list_to_integer(atom_to_list(Port)).

details(DetailsL) ->
% in:  {{'host', '127.0.0.1'}, {'name', 'foo0'}, {'password', 'foo0p4ss'}, {'port', '3306'}, {'user', 'mysqlu'}}
% out: 
%   [
%       mysql_host = string(),
%       mysql_port = integer(),
%       mysql_user = string(),
%       mysql_password = string(),
%       mysql_database = string(),
%       fun mysql_log/4 = function()
%   ]
    Details = tuple_to_list(DetailsL),
    {'host', Host} = lists:keyfind('host', 1, Details),
    {'port', Port} = lists:keyfind('port', 1, Details),
    {'user', User} = lists:keyfind('user', 1, Details),
    {'password', Password} = lists:keyfind('password', 1, Details),
    {'name', Database} = lists:keyfind('name', 1, Details),
    [   
        atom_to_host(Host),
        atom_to_port(Port),
        atom_to_list(User),
        atom_to_list(Password),
        atom_to_list(Database),
        fun(_Module, _Line, _Level, _FormatFun) -> ok end 
    ].  

spec(Module, {Name, Details}) ->
    {connection_pool:get_proc_name({Module, Name}),
      {connection_pool, start_link, [{Module, Name}, Details]},
      permanent, 2000, worker, case Module of ?MODULE -> []; _ -> [Module] end ++ [connection_pool, ?MODULE]}.

spec(Details) ->
    spec(?MODULE, Details).
    
connect(Name) ->
    Details = connection_pool:endpoint_details(Name), 
    Encoding = undefined,
    case apply(mysql2_conn, start_link, Details ++ [Encoding]) of
        {ok, Conn} ->
            Conn;
        Err ->
            exit({mysql, Err})
    end.

initialize(Name) ->
    Conn = connect(Name),
    MonitorRef = erlang:monitor(process, Conn),
    life_loop({Name, Conn, MonitorRef}).

initialize(Name, _Loop) ->
    initialize(Name).

life_loop(Details = {Name, Conn, ConnMonitorRef}) ->
    receive Msg ->
        case Msg of
            {_From, reconnect} ->
                erlang:demonitor(ConnMonitorRef),
                true = exit(Conn, normal),
                initialize(Name);
            _ ->
                connection_pool:handle_conn_loop_msg(fun life_loop/1,
                                                     Msg,
                                                     Details)
        end
    after ?PING_INTERVAL ->
        {data, _} = mysql2_conn:fetch(Conn, <<"select true">>, self()),
        life_loop(Details)
    end.
