-type node_id() :: {inet:ip_address(), inet:port_number()}.

-define(DEBUG(Msg), io:format("DEBUG: ~p~n", [Msg])).
