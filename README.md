hyparerl
========
This is an implementation of the Hybrid Partial View membership protocol, or simply HyParView.
The paper can be found at: http://docs.di.fc.ul.pt/jspui/bitstream/10455/2981/1/07-13.pdf

Consult the paper for protocol specific questions.

The protocol is implemented as an Erlang-application, according to the OTP-standards. The supervison-tree looks like this:

             hyparerl_sup
              /         \
       hypar_node      connect_sup
                           |
                        connect

A quick rundown of what each module does:

*hyparerl_sup:*
        Top-level supervisor


*hypar_node:*
        Contains all the node logic and protocol implementation


*connect_sup:*
        A socket-acceptor that accepts incoming connections and supervises all open connections.


*connect:*
        A module that takes care of open connections, does some serialization and multiplexing of control-messages as well as ordinary messages.


Application parameters
=======================
* *id*: The identifier, should be a tuple of {IPNumber, PortNumber}. PortNumber may NOT be set to ?TEMP_PORT(5999). Should make this a configurable parameter. Default {{127,0,0,1}, 6000} (IP: 127.0.0.1, Port: 6000).
* *active_size*: The size of the active view. Default 5.
* *passive_size*: The size of the passive view. Default 30.
* *arwl*: Active Random Walk Length. Default 6.
* *prwl*: Passive Random Walk Length. Default 3.
* *kactive*: The number of nodes to take from active view when doing a shuffle. Default 3.
* *kpassive*: The number of nodes to take from the passive view when doing a shuffle. Default 4.
* *shuffle_period*: Defines the cyclic period of when to do a shuffle in milliseconds. Default 10000.
* *shuffle_buffer*: Defines how large the shuffle history should be in number of shuffles. Default 5.
* *contact_node*: Defines a contact node that the node may try an connect to right away at startup. Default none. (o)
* *recipient*: The registered process which should receive all messages sent to this node. Default none. (o)
* *notify*: The registered process which should receive neighbourup and neighbourdown events. (Used in plumtree). Default none. (o)

Parameters marked (o) are optional.

A note about the recipient and notify processes are that as it is now they have to be gen_servers. This might change.

The parameters active_size, passive_size, arwl, prwl, kactive, kpassive, shuffle_period SHOULD be the same across the cluster. If they are not then the operation of the application is undefined.