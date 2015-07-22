%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 SyncFree Consortium.  All Rights Reserved.
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

%% This vnode stores received transactions in the log, making sure that its causal dependencies are preserved.

-module(new_inter_dc_dep_vnode).
-behaviour(riak_core_vnode).
-include("antidote.hrl").

-record(state, {
  partition :: partition_id(),
  queue :: queue()
}).

-export([handle_transaction/1]).
-export([init/1, handle_command/3, handle_coverage/4, handle_exit/3, handoff_starting/2, handoff_cancelled/1, handoff_finished/2, handle_handoff_command/3, handle_handoff_data/2, encode_handoff_item/2, is_empty/1, terminate/2, delete/1, start_vnode/1]).


init([Partition]) -> {ok, #state{partition = Partition, queue = queue:new()}}.
start_vnode(I) -> riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

handle_command({txn, Txn}, _Sender, State=#state{queue=Queue}) ->
  {reply, ok, process_queue(State#state{queue = queue:in(Txn, Queue)})}.

process_queue(State=#state{queue=Queue}) ->
  case queue:peek(Queue) of
    empty -> State;
    {value, Txn} ->
      case try_store(Txn) of
        false -> State;
        true -> process_queue(State#state{queue = queue:drop(Queue)})
      end
  end.

try_store(Txn) ->
  {_PDCID, Ops} = Txn,
  CommitOp = lists:last(Ops),
  CommitPld = CommitOp#operation.payload,
  commit = CommitPld#log_record.op_type,
  TxId = CommitPld#log_record.tx_id,
  LogPld = CommitPld#log_record.op_payload,
  {{_DcId, _TxCommitTime}, SnapshotTime} = LogPld,
  lager:info("Handling transaction tx_id=~p with deps=~p", [TxId, dict:to_list(SnapshotTime)]),
  true.

handle_coverage(_Req, _KeySpaces, _Sender, State) -> {stop, not_implemented, State}.
handle_exit(_Pid, _Reason, State) -> {noreply, State}.
handoff_starting(_TargetNode, State) -> {true, State}.
handoff_cancelled(State) -> {ok, State}.
handoff_finished(_TargetNode, State) -> {ok, State}.
handle_handoff_command(_Message, _Sender, State) -> {noreply, State}.
handle_handoff_data(_Data, State) -> {reply, ok, State}.
encode_handoff_item(_ObjectName, _ObjectValue) -> <<>>.
is_empty(State) -> {true, State}.
terminate(_Reason, _ModState) -> ok.
delete(State) -> {ok, State}.

%%%%%%%%%%%%%%%%%%%%%%%%

handle_transaction(Txn = {{_, P}, _}) -> dc_utilities:call_vnode(P, new_inter_dc_dep_vnode_master, {txn, Txn}).


