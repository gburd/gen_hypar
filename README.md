Intro
========
This is an implementation in Erlang of the Hybrid Partial View membership protocol, or simply HyParView. The paper can be found at: http://docs.di.fc.ul.pt/jspui/bitstream/10455/2981/1/07-13.pdf
Consult the paper for protocol specific questions.

Quickstart
==========
To start a new cluster node we call any of the start-functions:

```
hyparerl:start()
hyparerl:start(Options)
```

```hyparerl:start/0``` expects all neccessary parameters to be defined. Whereas ```hyparerl:start/1``` overwrites all parameters with the ones provided in the argument. To successfully start a node the parameters ```id``` and ```mod```, the identifier and callback module, must be explicitly defined. All other options can be defaulted but are of course configurable.

Callback module
===============
The callback module must define 3 functions:
```
deliver(Sender :: id(), Bin :: binary()) -> ok.
link_up(Peer :: #peer{}) -> ok.
link_down(NodeId) -> ok.
```
where the record ```#peer{}``` is defined in the hyparerl.hrl include file as:

```
-record(peer, {id   :: id(),
               conn :: pid()}).
```

Operation
=========

Sending
-------
All this is rather useless if we can't do anything with our peers! So of course we have the function:
```hyparerl:send(Peer :: #peer{}, Message :: binary()) -> ok``` with which we can send binary data to our peers.

Retrive peers
-------------
One can imagine a scenario where we just don't care about the link change events(or delivery of messages but that seems unlikely). In that mode of operation we can instead(or also) use the function: ```hyparerl:get_peers()```. This will return a list of all current active peers.

Application parameters
======================
* *id*: The identifier, should be a tuple of {Ip, Port}. 
* *mod*: The callback module.
* *active_size*: The size of the active view. Default 5.
* *passive_size*: The size of the passive view. Default 30.
* *arwl*: Active Random Walk Length. Default 6.
* *prwl*: Passive Random Walk Length. Default 3.
* *k_active*: The number of nodes to take from active view when doing a shuffle. Default 3.
* *k_passive*: The number of nodes to take from the passive view when doing a shuffle. Default 4.
* *shuffle_period*: Cyclic period timer of when to do a shuffle in milliseconds. Default 10000.
* *timeout*: Define the timeout value when receiving data, if a timeout occurs that node is considered dead. Default 10000.
* *send_timeout*: Same as above but when we send data. Default 10000.
* *contact_nodes*: A list of nodes to try and join to. Optional.

All parameters SHOULD be the same across the cluster. All other configurations are untested and the operation of the application is undefined.