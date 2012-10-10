%% -------------------------------------------------------------------
%% @author Emil Falk <emil.falk.1988@gmail.com>
%% @copyright (C) 2012, Emil Falk
%% @title Include file
%% @doc Defines records & types used in gen_hypar
%% -------------------------------------------------------------------

%% @doc An <em>identifier</em> is a tuple of an IP address and port number
-type id() :: {inet:ip_address(),
               inet:port_number()}.

%% Size of an identifier in bytes
-define(IDSIZE, 6).

%% @doc Represent the priority of a neighbour request
-type priority() :: high | low.

%% @doc Represent the options
-type options() :: list(option()).

%% @doc All valid options
-type option() ::
        {active_size, pos_integer()}    | %% Maximum number of active links
        {passive_size, pos_integer()}   | %% Maximum number of passive nodes
        {arwl, pos_integer()}           | %% Active random walk length
        {prwl, pos_integer()}           | %% Passive random walk length
        {k_active, pos_integer()}       | %% k samples from active view in shuffle
        {k_passive, pos_integer()}      | %% k samples from passive view in shuffle
        {shuffle_period, pos_integer()} | %% Shuffle period timer in milliseconds
        {timeout, timeout()}            | %% Receive timeout, when to consider nodes dead
        {send_timeout, timeout()}.        %% Send timeout, when to consider nodes dead

%% @doc Type of an active peer: {Identifier, CtlPid, SendPid}
-type peer() :: {id(), pid()}. 

%% @doc Type of active view
-type active_view() :: list(peer()).

%% @doc A list of peer ids
-type view() :: list(id()).

%% @doc Type synonym, view()
-type passive_view() :: view().

%% @doc Exchange lists are only a list of ids
-type xlist() :: view().

%% @doc Internal type for time to live
-type ttl() :: non_neg_integer().
