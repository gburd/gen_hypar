all:
	rebar compile

clean:
	rebar clean

testcluster:
	erl -detached -pa ebin/ deps/*/ebin -name "node6000@localhost" -cookie kaka -eval "hyparerl:start()"
	for p in {6001..6010}
	do
		erl -detached -pa ebin/ deps/*/ebin -name "node$p@localhost" -cookie kaka -eval "hyparerl:test_start($p)"
	done

killcluster:
	pkill beam
