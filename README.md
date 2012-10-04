#hyparerl
---------
This is an implementation in Erlang of the [Hybrid Partial View][] membership protocol by João Leitão, José Pereira and Luís Rodrogies.

[Hybrid Partial View]: http://docs.di.fc.ul.pt/jspui/bitstream/10455/2981/1/07-13.pdf

##Quickstart

###Firing up a node
A node is defined by it's unique identifer `{Ip, Tuple}` on which the node is reachable.

To start a new node we call any of the start-functions:

               hyparerl:start()
               hyparerl:start(Options)

* `start/0` starts the node on a random port and tries to default an ip-address. It is of course configurable via the     usual application interface.
* `start/1` starts with the list of options given. 

To configure another ip address and port use the **id** option. See all options below. The options should be the same for all nodes in a cluster. 

###Enter the cluster

The node is started isolated and alone until it is joined to the cluster using:

               hyparerl:join_cluster(Node)
               hyparerl:join_cluster(Nodes)
               
Where either a single node `Node` is provided or a list `Nodes`. The list is tried in order. There is also the option to define a list of contact nodes with the **contact_nodes** option. Use with caution, if something goes wrong the Erlang way of fail-fast might not be guarantueed.

If the node recovers from some previous error and start up again on the same ip and port then there is the possibility that it automatically rejoins the cluster.

###Where are the peers?
When the node has joined the cluster the current peers can be retrived with:

               hyparerl:get_peers()

###Sending data
To send data you first need to have a `Peer` retrived either via the above method or using the callback functions explained below. Anyhow the function to use is:
               
               hyparerl:send(Peer, Message)

The `Message` can be either a `binary()` or an `iolist()`. 

###Retriving data and the callback module
The callback option **mod** should be a module that defines three functions:
               
               Mod:deliver(Peer, Message) -> ok
               Mod:link_up(Peer)          -> ok.
               Mod:link_down(Peer         -> ok

When a binary `Message` is received from `Peer` `deliver/2` is called. Upon link changes when a `Peer` either goes up or down `link_up/1`, `link_down/1` are executed.

###Application options
<table>
 <tr><td> **id**             </td><td> The unique identifier. It is a tuple `{Ip, Port}`.</td></tr>
 <tr><td> **mod**            </td><td> The callback module.</td></tr>
 <tr><td> **active_size**    </td><td> The size of the active view. Default 5. </td></tr>
 <tr><td> **passive_size**   </td><td> The size of the passive view. Default 30.</td></tr>
 <tr><td> **arwl**           </td><td> Active Random Walk Length. Default 6.</td></tr>
 <tr><td> **prwl**           </td><td> Passive Random Walk Length. Default 3.</td></tr>
 <tr><td> **k_active**       </td><td> The number of nodes sampled from the active view when doing a shuffle. Default 3.</td></tr>
 <tr><td> **k_passive**      </td><td> Same as above but with passive view. Default 4.</td></tr>
 <tr><td> **shuffle_period** </td><td> Cyclic period timer of when to do a shuffle in milliseconds. Default 10000.</td></tr>
 <tr><td> **timeout**        </td><td> Define the timeout value when receiving data, if a timeout occurs that node is considered dead. Default 10000.</td></tr>
 <tr><td> **send_timeout**   </td><td> Same as above but when data is sent. Default 10000.</td></tr>
 <tr><td> **contact_nodes**  </td><td> A list of nodes to try and join to. Default [].</td></tr>
</table