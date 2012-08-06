hyparerl
========
This is an implementation of the Hybrid Partial View membership protocol, or simply HyParView.
The paper can be found at: http://docs.di.fc.ul.pt/jspui/bitstream/10455/2981/1/07-13.pdf

Consult the paper for protocol specific questions.

The protocol is implemented as an Erlang-application, according to the OTP-standards. The supervison-tree looks like this:

             hyparerl_sup
              /         \
       hypar_man       connect_sup
                           |
                        connect

A quick rundown of what each module does:

*hyparerl_sup:*
        Top-level supervisor


*hypar_man:*
        Contains all the node logic and protocol implementation


*connect_sup:*
        A socket-acceptor that accepts incoming connections and supervises all open connections.


*connect:*
        A module that takes care of open connections, does some serialization and multiplexing of control-messages as well as ordinary messages.


Application parameters
=======================
* *active_size*: The size of the active view.
* *passive_size*: The size of the passive view.
* *arwl*: Active Random Walk Length.
* *prwl*: Passive Random Walk Length.
* *kactive*: The number of nodes to take from active view when doing a shuffle.
* *kpassive*: The number of nodes to take from the passive view when doing a shuffle.
* *ip*: Which the local interface/ip address to use.
* *port*: Which the local port to use.
* *shuffle_period*: Defines the cyclic period of when to do a shuffle.
* *contact_node*: Defines a contact node that the node may try an connect to right away at startup.
* *recipient*: The registered process which should receive all messages sent to this node.
* *notify*: The registered process which should receive neighbourup and neighbourdown events. (Used in plumtree).


