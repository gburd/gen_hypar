-module(hypar_node_test).

-define(WAIT_TIME, 10000).

-compile([export_all]).

setup_mock() ->
    meck:new(connect_sup),
    meck:expect(connect_sup, start_connection,
                fun mock_connect_sup:start_connection/2),
    meck:expect(connect_sup, start_temp_connection,
                fun mock_connect_sup:start_temp_connection/2),
    meck:expect(connect_sup, init,
                fun mock_connect_sup:init/1),
    meck:expect(connect_sup, start_listener,
                fun mock_connect_sup:start_listener/0).

hypar_node_test() ->
    start_nodes(),
    join_nodes(),
    timer:sleep(?WAIT_TIME),
    
    check_cluster_graph().

start_nodes() ->
    lists:foreach(fun start_node/1, [node()|nodes()]),

start_node(Node) ->
    rpc:cast(Node, ?MODULE, setup_mock, []),
    rpc:cast(Node, application, load, [hyparerl]),
    rpc:cast(Node, application, set_env, [hyparerl, id, Node]),
    rpc:cast(Node, application, start, [hyparerl]).

join_nodes() ->
    ThisNode = node(),
    lists:foreach(fun(Node) ->
                          rpc:cast(Node, hypar_node, join_cluster, ThisNode)
                  end, nodes()).

check_cluster_graph() ->
    Nodes = [node()|nodes()],

    G = digraph:new(),
    
    lists:foreach(fun(Node) ->
                          digraph:add_vertex(G, Node)
                  end, Nodes),
    lists:foreach(fun(Node) ->
                          lists:foreach(fun(Peer) ->
                                                digraph:add_edge(G, Node, Peer)
                                        end, get_peers_node(Node))
                  end, Nodes),
    
                                        
get_peers_node(Node) ->
    gen_server:call({hypar_node, Node}, get_peers).
