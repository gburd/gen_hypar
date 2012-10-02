%% -------------------------------------------------------------------
%% Copyright (c) 2012 Emil Falk  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
%% @author Emil Falk <emil.falk.1988@gmail.com>
%% @copyright (C) 2012, Emil Falk
%% @title Include file
%% @doc Defines records & types used in hyparerl
%% -------------------------------------------------------------------

%% @doc An <em>identifier</em> is a tuple of an IP address and port number
-type id() :: {inet:ip_address(),
               inet:port_number()}.

%% @doc Type for shuffle history entries
-type shuffle_ent() :: {integer(), list(id()), erlang:timestamp()}.

%% @doc Type for the shuffle history
-type shuffle_history() :: list(shuffle_ent()).

%% @doc Represent the priority of a neighbour request
-type priority() :: high | low.

%% @doc Process name or pid
-type proc() :: pid() | atom().

%% @doc Represent the options
-type options() :: list(option()).

%% @doc All valid options
-type option() ::
        {id, id()}                      | %% Node identifier
        {active_size, pos_integer()}    | %% Maximum number of active links
        {passive_size, pos_integer()}   | %% Maximum number of passive nodes
        {arwl, pos_integer()}           | %% Active random walk length
        {prwl, pos_integer()}           | %% Passive random walk length
        {k_active, pos_integer()}       | %% k samples from active view in shuffle
        {k_passive, pos_integer()}      | %% k samples from passive view in shuffle
        {shuffle_period, pos_integer()} | %% Shuffle period timer in milliseconds
        {contact_nodes, list(id())}     | %% Nodes to join a cluster via
        {mod, module()}                 | %% Callback module with linkup/down and deliver functions
        {timeout, timeout()}            | %% Receive timeout, when to consider nodes dead
        {send_timeout, timeout()}.        %% Send timeout, when to consider nodes dead

%% @doc A <em>peer</em> consists of an identifier and a corresponding pid
-record(peer, {id  :: id(),
               conn :: pid()
              }).

%% @doc A view
-type view() :: list(id()).

%% @doc Type of active view
-type active_view() :: list(#peer{}).

%% @doc Type of the passive view
-type passive_view() :: view().

%% @doc Exchange list are the same as a passive view
-type xlist() :: view().
