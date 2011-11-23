%
% (c) Rdio 2011
%

-module(connection_pool_utils).

-compile(export_all).

pools(Type, Defs) ->
    lists:foldl(fun({Name, Nodes}, L) ->
                    generate_pool(Type, Name, Nodes, L)
                end, [], Defs).

generate_pool(_Type, _Name, [], L) ->
    L;

generate_pool(Type, Name, [{'master', Details} | Rest], L) ->
    generate_pool(Type, Name, Rest, [{Name,  Details} | L]);

generate_pool(Type, Name, [{'slaves', SL} | Rest], L) ->
    generate_pool(Type, Name, Rest, generate_slaves(Type, Name, SL, 1, L)).

generate_slaves(_Type, _BaseName, [], _C, L) ->
    L;
generate_slaves(Type, BaseName, [Details | Rest], C, L) ->
    Name = slave_name(BaseName, C),
    generate_slaves(Type, BaseName, Rest, C + 1, [{Name, Details} | L]).

slave_name(BaseName, C) ->
    list_to_atom(lists:concat([BaseName, ":slave:", C])).
