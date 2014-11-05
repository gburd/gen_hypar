DIALYZER_APPS = kernel stdlib sasl erts ssl tools os_mon runtime_tools crypto inets \
	public_key mnesia syntax_tools compiler
PULSE_TESTS =
ERL = $(shell which erl)
ifeq ($(ERL),)
	$(error "Erlang not available on this system")
endif
ERLFLAGS= -pa $(CURDIR)/.eunit -pa $(CURDIR)/ebin -pa $(CURDIR)/deps/*/ebin
REBAR=$(shell which rebar)
ifeq ($(REBAR),)
	$(error "Rebar not available on this system")
endif

.PHONY: deps test

all: deps compile

compile: deps
	$(REBAR) compile

deps:
	$(REBAR) get-deps

clean:
	$(REBAR) clean

distclean: clean
	$(REBAR) delete-deps

qc: clean all
	$(REBAR) -C rebar_eqc.config compile eunit skip_deps=true --verbose

eqc-ci: clean all
	$(REBAR) -D EQC_CI -C rebar_eqc_ci.config compile eunit skip_deps=true --verbose

# You often want *rebuilt* rebar tests to be available to the shell you have to
# call eunit (to get the tests rebuilt). However, eunit runs the tests, which
# probably fails (thats probably why You want them in the shell). This
# (prefixing the command with "-") runs eunit but tells make to ignore the
# result.
repl shell: deps compile
	- @$(REBAR) skip_deps=true eunit
	@$(ERL) $(ERLFLAGS)

# You should 'clean' before your first run of this target
# so that deps get built with PULSE where needed.
pulse:
	$(REBAR) compile -D PULSE
	$(REBAR) eunit -D PULSE skip_deps=true suite=$(PULSE_TESTS)

include tools.mk
