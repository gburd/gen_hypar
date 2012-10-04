#hyparerl
---------
This is an implementation in Erlang of the [Hybrid Partial View][] membership protocol by João Leitão, José Pereira and Luís Rodrogies.

[Hybrid Partial View]: http://docs.di.fc.ul.pt/jspui/bitstream/10455/2981/1/07-13.pdf

##Quickstart

###Firing up a node
A node is defined by it's unique identifer `{Ip, Tuple}` on which it is reachable.

To start a new node we call any of the start-functions:

               hyparerl:start()
               hyparerl:start(Options)

* `start/0` starts the node on a random port and tries to default an ip-address. It is of course configurable via the     usual application interface.
* `start/1` starts with the list of options given. 

To configure another ip address and port use the **id** option. It's also possible to only define the ip or the port with the **ip** and **port**. If the whole identifier is not know it can be retrived using:

               hyparerl:get_id()

There are alot more options and all of them are listed at the [bottom](#application-options). The options should be the same for all nodes in a cluster and otherwise the semantics of the program is not well defined.

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

###Example
There is an example application included in examples/flooder.erl. flooder is a reliable flooding broadcaster, though very simple.

               erlc -o ebin -I include/ examples/flooder.erl
               erl -pa ebin/ -pa ebin/*/deps -eval 'flooder:start_link()'
               ...
               05:02:16.926 [info] Initializing: {{192,168,1,138},APort}...

Then fire up a couple of terminals and in each of them connect them to each other or to the original node. `start_link/1` need only a port and connects locally.

               erl -pa ebin/ -pa ebin/*/deps -eval 'flooder:start_link(APort)'
               ...
               05:03:12.416 [info] Initializing: {{192,168,1,138},AnotherPort}...
               ...
               05:03:12:523 [info] Link up: {peer, {{192,168,1,138},APort}}
               
As more nodes join more links will become available and eventually (if you for example join 6 nodes to the first one), start to go down also as nodes reach their maximum fanout. Then try to send a couple of messages from different nodes:
       
               1> flooder:broadcast(<<"PLEASE WORK, BRAIN SLEEP NEEDS!>>).
               ok
               2> Packet delivered:
               <<"PLEASE WORK, BRAIN SLEEP NEEDS!>>

And hopefully all nodes should receive that message. Try playing around with it, killing some nodes, joining others and sending messages in between. 

##Other projects on top of hyparerl
Check out [plumcast][], it's in early development. It is an implementation of the Plumtree protocol developed by the same guys. Plumcast builds a broadcast tree on top of hyparerl to reduce the network traffic without sacrificing to much latency.

Also check out [floodcast][], also very early development, that will basically be a more serious implementation of the simple flooder example.

[plumcast]: emfa/plumcast
[floodcast]: emfa/floodcast

##Application options
<table>
 <tr><td> **id**             </td><td> The unique identifier. It is a tuple `{Ip, Port}`.</td><td>IP∈IfList<br>Port=Random</td></tr>
 <tr><td> **ip**             </td><td> Define only the ip address. </td><td>IP∈IfList</td></tr>
 <tr><td> **port**           </td><td> Define only the port. </td><td>Port=Random</td></tr>
 <tr><td> **mod**            </td><td> The callback module.</td><td>No-op</td></tr>
 <tr><td> **active_size**    </td><td> Maximum entries in the active view.</td><td>5</td></tr>
 <tr><td> **passive_size**   </td><td> Same as above but for passive view.</td><td>30</td></tr>
 <tr><td> **arwl**           </td><td> Active Random Walk Length.</td><td>6</td></tr>
 <tr><td> **prwl**           </td><td> Passive Random Walk Length.</td><td>3</td></tr>
 <tr><td> **k_active**       </td><td> The number of nodes sampled from the active view when doing a shuffle.</td><td>3</td</tr>
 <tr><td> **k_passive**      </td><td> Same as above but with passive view.</td><td>4</td></tr>
 <tr><td> **shuffle_period** </td><td> Cyclic period timer of when to do a shuffle in milliseconds.</td><td>10000</td></tr>
 <tr><td> **timeout**        </td><td> Define the timeout value when receiving data, if a timeout occurs that node is considered dead.</td><td>10000</td></tr>
 <tr><td> **send_timeout**   </td><td> Same as above but when data is sent.</td><td>10000</td></tr>
 <tr><td> **contact_nodes**  </td><td> A list current cluster members to join to.</td><td>[]</td></tr>