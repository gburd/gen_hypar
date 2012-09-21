%% -------------------------------------------------------------------
%%
%% Utility module for hyparerl
%%
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

%% @doc Utility functions and/or functions that doesn't fit anywhere else.
%%      Mostly random functions
-module(misc).

-author('Emil Falk <emil.falk.1988@gmail.com>').

%% API
-export([drop_return/2, drop_nth/2, random_elem/1, take_n_random/2,
         drop_random/1, drop_n_random/2]).

%%%===================================================================
%%% API
%%%===================================================================

-spec drop_return(N :: pos_integer(), List :: list(T)) -> {T,list(T)}.
%% @pure
%% @doc Drops the <em>N'th</em> element of <em>List</em> returning both
%%      the dropped element and the resulting list.
drop_return(N, List) ->
    drop_return(N, List, []).

-spec drop_nth(N :: pos_integer(), List :: list(T)) -> list(T).
%% @pure
%% @doc Drop the <em>N'th</em> element of <em>List</em>.
drop_nth(N, List0) ->
    {_, List} = drop_return(N, List0),
    List.

-spec random_elem(List :: list(T)) -> T.
%% @doc Get a random element of <em>List</em>.
random_elem(List) ->
    I = random:uniform(length(List)),
    lists:nth(I, List).

-spec take_n_random(N :: non_neg_integer(), List :: list(T)) -> list(T).
%% @doc Take <em>N</em> random elements from <em>List</em>.
take_n_random(N, List) -> 
    take_n_random(N, List, length(List)).

-spec drop_random(List :: list(T)) -> {T, list(T)}.
%% @doc Removes a random element from <em>List, returning
%%      the new list and the dropped element.
drop_random(List) ->
    N = random:uniform(length(List)),
    drop_return(N, List).

-spec drop_n_random(N :: pos_integer(), List :: list(T)) -> list(T).
%% @doc Removes n random elements from the list
drop_n_random(N, List) when N >= 0 -> drop_n_random(List, N, length(List));
drop_n_random(_, List) -> List.


%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec take_n_random(N :: non_neg_integer(), L :: list(T),
                    Len :: non_neg_integer()) -> list(T).
%% @doc Helper function for take_n_random/2.
take_n_random(0, _, _) -> [];
take_n_random(_, _, 0) -> [];
take_n_random(N, L, Len) ->
    I = random:uniform(Len),
    {E, L1} = drop_return(I, L),
    [E|take_n_random(N-1, L1, Len)].

-spec drop_return(N :: pos_integer(), L :: list(T), S :: list(T))
                 -> {T, list(T)}.
%% @pure
%% @doc Helper function for drop_return/2
drop_return(1, [H|T], S) -> {H, lists:reverse(S) ++ T};
drop_return(N, [H|T], S) -> drop_return(N-1, T, [H|S]).

-spec drop_n_random(L :: list(T), N :: non_neg_integer(),
                    Len :: non_neg_integer()) -> list(T).
%% @doc Helper-function for drop_n_random/2
drop_n_random(L, 0, _) -> L;
drop_n_random(_, _, 0) -> [];
drop_n_random(L, N, Len) ->
    I = random:uniform(Len),
    {_, L} = drop_return(I, L),
    drop_n_random(L, N-1, Len-1).
