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
%%% @author Emil Falk <emil.falk.1988@gmail.com>
%%% @copyright (C) 2012, Emil Falk
%%% @title Include file for connect.erl
%%% @doc Defines the messages sent over the network via the connect
%%%      module
%%%-------------------------------------------------------------------

%% Byte representation of the different messages
-define(MESSAGE,      1). %% Payload message
-define(JOIN,         2). %% Join message
-define(FORWARDJOIN,  3). %% Forward join message
-define(JOINREPLY,    4). %% Forward join reply
-define(HNEIGHBOUR,   5). %% High priority neighbour request
-define(LNEIGHBOUR,   6). %% Low priority neighbour request
-define(SHUFFLE,      7). %% Shuffle request
-define(SHUFFLEREPLY, 8). %% Shuffle reply message
-define(DISCONNECT,   9). %% Disconnect message

-define(DECLINE, 0). %% Decline a neighbour request
-define(ACCEPT,  1). %% Accept a neighbour request
