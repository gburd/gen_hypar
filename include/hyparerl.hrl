-record(node, {ip   :: inet:ip_address(),
               port :: inet:port_number()}).

-type option() :: {atom(), any()}.

-define(DEBUG(Msg), io:format("DEBUG: ~p~n", [Msg])).
