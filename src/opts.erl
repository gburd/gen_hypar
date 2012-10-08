%%%===================================================================
%%% Options related
%%%===================================================================
-module(opts).

-include("hyparerl.hrl").

-export([myself/1, arwl/1, prwl/1, active_size/1, passive_size/1, k_active/1,
         k_passive/1, callback/1, shuffle_period/1, timeout/1, send_timeout/1,
         connect_sup/1, hypar/1, name/1, connect_opts/1, default_opts/1]).

%% Functions to nicen up the code abit
myself(Opts)         -> proplists:get_value(id, Opts).
arwl(Opts)           -> proplists:get_value(arwl, Opts).
prwl(Opts)           -> proplists:get_value(prwl, Opts).
active_size(Opts)    -> proplists:get_value(active_size, Opts).
passive_size(Opts)   -> proplists:get_value(passive_size, Opts).      
k_active(Opts)       -> proplists:get_value(k_active, Opts).
k_passive(Opts)      -> proplists:get_value(k_passive, Opts).
callback(Opts)       -> proplists:get_value(mod, Opts, noop).
shuffle_period(Opts) -> proplists:get_value(shuffle_period, Opts).
timeout(Opts)        -> proplists:get_value(timeout, Opts).
send_timeout(Opts)   -> proplists:get_value(send_timeout, Opts).
connect_sup(Opts)    -> proplists:get_value(connect_sup, Opts).
name(Opts)           -> proplists:get_value(name, Opts).
hypar(Opts)          -> proplists:get_value(hypar, Opts).

-spec connect_opts(Options :: options()) -> options().
%% @pure
%% @doc Filter out the options related to this module
connect_opts(Options) ->
    Valid = [id, mod, timeout, send_timeout],
    lists:filter(fun({Opt,_}) -> lists:member(Opt, Valid) end, Options).                         

%% @doc Check so all neccessary options are defined, otherwise default them.
default_opts(Options) ->
    lists:foldl(fun({Opt, _}=OptPair, Acc0) ->
                        case proplists:is_defined(Opt, Acc0)  of
                            true -> Acc0;
                            false -> [OptPair|Acc0]
                        end
                end, Options, default_options()).

%% @doc Default options for the hyparview-application
default_options() ->
    [{active_size, 5},
     {passive_size, 30},
     {arwl, 6},
     {prwl, 3},
     {k_active, 3},
     {k_passive, 4},
     {shuffle_period, 10000},
     {timeout, 10000},
     {send_timeout, 10000}].
