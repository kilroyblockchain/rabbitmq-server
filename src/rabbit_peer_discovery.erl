%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is Pivotal Software, Inc.
%% Copyright (c) 2007-2017 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_peer_discovery).

%%
%% API
%%

-export([discover_cluster_nodes/0, backend/0, node_type/0,
         normalize/1, format_discovered_nodes/1, log_configured_backend/0,
         register/0, unregister/0, maybe_register/0, maybe_unregister/0,
         maybe_inject_randomized_delay/0]).
-export([append_node_prefix/1, node_prefix/0]).

-define(DEFAULT_BACKEND,   rabbit_peer_discovery_classic_config).
%% what node type is used by default for this node when joining
%% a new cluster as a virgin node
-define(DEFAULT_NODE_TYPE, disc).
%% default node prefix to attach to discovered hostnames
-define(DEFAULT_PREFIX, "rabbit").
%% default randomized delay range, in seconds
-define(DEFAULT_STARTUP_RANDOMIZED_DELAY, {5, 60}).

-define(NODENAME_PART_SEPARATOR, "@").


-spec backend() -> atom().

backend() ->
  case application:get_env(rabbit, autocluster) of
    {ok, Proplist} ->
      proplists:get_value(peer_discovery_backend, Proplist, ?DEFAULT_BACKEND);
    undefined      ->
      ?DEFAULT_BACKEND
  end.



-spec node_type() -> rabbit_types:node_type().

node_type() ->
  case application:get_env(rabbit, autocluster) of
    {ok, Proplist} ->
      proplists:get_value(node_type, Proplist, ?DEFAULT_NODE_TYPE);
    undefined      ->
      ?DEFAULT_NODE_TYPE
  end.



-spec log_configured_backend() -> ok.

log_configured_backend() ->
  rabbit_log:info("Configured peer discovery backend: ~s~n", [backend()]).


-spec discover_cluster_nodes() -> {ok, Nodes :: list()} |
                                  {ok, {Nodes :: list(), NodeType :: rabbit_types:node_type()}} |
                                  {error, Reason :: string()}.

discover_cluster_nodes() ->
    Backend = backend(),
    normalize(Backend:list_nodes()).


-spec maybe_register() -> ok.

maybe_register() ->
  Backend = backend(),
  case Backend:supports_registration() of
    true  ->
      register(),
      Backend:post_registration();
    false ->
      rabbit_log:info("Peer discovery backend ~s does not support registration, skipping registration.", [Backend]),
      ok
  end.


-spec maybe_unregister() -> ok.

maybe_unregister() ->
  Backend = backend(),
  case Backend:supports_registration() of
    true  ->
      unregister();
    false ->
      rabbit_log:info("Peer discovery backend ~s does not support registration, skipping unregistration.", [Backend]),
      ok
  end.


-spec maybe_inject_randomized_delay() -> ok.
maybe_inject_randomized_delay() ->
  Backend = backend(),
  case Backend:supports_registration() of
    true  ->
      rabbit_log:info("Peer discovery backend ~s supports registration.", [Backend]),
      inject_randomized_delay();
    false ->
      rabbit_log:info("Peer discovery backend ~s does not support registration, skipping randomized startup delay.", [Backend]),
      ok
  end.

-spec inject_randomized_delay() -> ok.

inject_randomized_delay() ->
    {Min, Max} = case randomized_delay_range_in_ms() of
                     {A, B} -> {A, B};
                     [A, B] -> {A, B}
                 end,
    case {Min, Max} of
        %% When the max value is set to 0, consider the delay to be disabled.
        %% In addition, `rand:uniform/1` will fail with a "no function clause"
        %% when the argument is 0.
        {_, 0} ->
            rabbit_log:info("Randomized delay range's upper bound is set to 0. Considering it disabled."),
            ok;
        {_, N} when is_number(N) ->
            rand:seed(exsplus),
            RandomVal  = rand:uniform(round(N)),
            rabbit_log:debug("Randomized startup delay: configured range is from ~p to ~p milliseconds, PRNG pick: ~p...",
                             [Min, Max, RandomVal]),
            Effective  = case RandomVal < Min of
                             true  -> Min;
                             false -> RandomVal
                         end,
            rabbit_log:info("Will wait for ~p milliseconds before proceeding with regitration...", [Effective]),
            timer:sleep(Effective),
            ok
    end.

-spec randomized_delay_range_in_ms() -> {integer(), integer()}.

randomized_delay_range_in_ms() ->
  {Min, Max} = case application:get_env(rabbit, autocluster) of
                   {ok, Proplist} ->
                       proplists:get_value(randomized_startup_delay_range, Proplist, ?DEFAULT_STARTUP_RANDOMIZED_DELAY);
                   undefined      ->
                       ?DEFAULT_STARTUP_RANDOMIZED_DELAY
               end,
    {Min * 1000, Max * 1000}.


-spec register() -> ok.

register() ->
  Backend = backend(),
  rabbit_log:info("Will register with peer discovery backend ~s", [Backend]),
  case Backend:register() of
    ok             -> ok;
    {error, Error} ->
      rabbit_log:error("Failed to register with peer discovery backend ~s: ~p",
        [Backend, Error]),
      ok
  end.


-spec unregister() -> ok.

unregister() ->
  Backend = backend(),
  rabbit_log:info("Will unregister with peer discovery backend ~s", [Backend]),
  case Backend:unregister() of
    ok             -> ok;
    {error, Error} ->
      rabbit_log:error("Failed to unregister with peer discovery backend ~s: ~p",
        [Backend, Error]),
      ok
  end.


%%
%% Implementation
%%

-spec normalize(Nodes :: list() |
                {Nodes :: list(), NodeType :: rabbit_types:node_type()} |
                {ok, Nodes :: list()} |
                {ok, {Nodes :: list(), NodeType :: rabbit_types:node_type()}} |
                {error, Reason :: string()}) -> {ok, {Nodes :: list(), NodeType :: rabbit_types:node_type()}} |
                                                {error, Reason :: string()}.

normalize(Nodes) when is_list(Nodes) ->
  {ok, {Nodes, disc}};
normalize({Nodes, NodeType}) when is_list(Nodes) andalso is_atom(NodeType) ->
  {ok, {Nodes, NodeType}};
normalize({ok, Nodes}) when is_list(Nodes) ->
  {ok, {Nodes, disc}};
normalize({ok, {Nodes, NodeType}}) when is_list(Nodes) andalso is_atom(NodeType) ->
  {ok, {Nodes, NodeType}};
normalize({error, Reason}) ->
  {error, Reason}.

-spec format_discovered_nodes(Nodes :: list()) -> string().

format_discovered_nodes(Nodes) ->
  string:join(lists:map(fun (Val) -> hd(io_lib:format("~s", [Val])) end, Nodes), ", ").



-spec node_prefix() -> string().

node_prefix() ->
    case string:tokens(atom_to_list(node()), ?NODENAME_PART_SEPARATOR) of
        [Prefix, _] -> Prefix;
        [_]         -> ?DEFAULT_PREFIX
    end.



-spec append_node_prefix(Value :: binary() | list()) -> atom().

append_node_prefix(Value) ->
    Val = rabbit_data_coercion:to_list(Value),
    Hostname = case string:tokens(Val, ?NODENAME_PART_SEPARATOR) of
                   [_ExistingPrefix, Val] ->
                       Val;
                   [Val]                  ->
                       Val
               end,
    string:join([node_prefix(), Hostname], ?NODENAME_PART_SEPARATOR).
