-type node_id() :: {inet:ip_address(), inet:port_number()}.

-record(state, {myself       :: node_id(),
                active  = [] :: list({node_id(), pid()}),
                passive = [] :: list(node_id()),
                active_size  :: pos_integer(),
                passive_size :: pos_integer(),
                arwl         :: pos_integer(),
                prwl         :: pos_integer(),
                k_active     :: pos_integer(),
                k_passive    :: pos_integer()
               }).
