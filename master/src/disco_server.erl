
-module(disco_server).
-behaviour(gen_server).

-export([start_link/0, stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, 
        terminate/2, code_change/3]).

-record(job, {jobname, partid, mode, prefnode, input, from}).

start_link() ->
        error_logger:info_report([{"DISCO SERVER STARTS"}]),
        case gen_server:start_link({local, disco_server}, 
                        disco_server, [], []) of
                {ok, Server} -> {ok, _} = disco_config:get_config_table(),
                                {ok, Server};
                {error, {already_started, Server}} -> {ok, Server}
        end.

stop() ->
        gen_server:call(disco_server, stop).

init(_Args) ->
        process_flag(trap_exit, true),

        % active_workers contains Pids of all running
        % disco_worker processes.
        ets:new(active_workers, [named_table, public]),

        % node_laod records how many disco_workers there are
        % running on a node (could be found in active_workers
        % as well). This table exists mainly for convenience and
        % possibly for performance reasons.
        ets:new(node_load, [named_table]),

        % blacklist contains globally blacklisted nodes 
        ets:new(blacklist, [named_table]),

        % node_stats contains triples {ok_jobs, failed_jobs, crashed_jobs}
        % for each node.
        ets:new(node_stats, [named_table]),

        {ok, Name} = application:get_env(disco_name),
        register(slave_master, spawn_link(fun() ->
                slave_master(lists:flatten([Name, "_slave"]))
        end)),
        {ok, []}.

handle_call({get_active, JobName}, _From, State) ->
        Tasks = ets:match(active_workers, {'_', {'_', JobName, '_', '$1', '_'}}),
        Nodes = ets:match(active_workers, {'_', {'_', JobName, '$1', '_', '_'}}),
        {reply, {ok, {Nodes, Tasks}}, State};

handle_call({get_nodeinfo, all}, _From, State) ->
        Active = ets:match(active_workers, {'_', {'_', '$2', '$1', '_', '_'}}),
        Available = lists:map(fun({Node, Max}) ->
                [{_, A, B, C}] = ets:lookup(node_stats, Node),
                BL = case ets:lookup(blacklist, Node) of
                        [] -> false;
                        _ -> true
                end,
                {obj, [{node, list_to_binary(Node)},
                       {job_ok, A}, {data_error, B}, {error, C}, 
                       {max_workers, Max}, {blacklisted, BL}]}
        end, ets:tab2list(config_table)),
        {reply, {ok, {Available, Active}}, State};

handle_call({get_nodeinfo, Node}, _From, State) ->
        case ets:lookup(node_stats, Node) of
                [] -> {reply, {ok, []}, State};
                [{_, V}] -> Nfo = ets:match(active_workers, 
                        {'_', {'_', '$1', Node, '_', '_'}}),
                        {reply, {ok, {V, Nfo}}, State}
        end;

handle_call({update_config_table, Config}, _From, State) ->
        error_logger:info_report([{'Config table update'}]),
        case ets:info(config_table) of
                undefined -> none;
                _ -> ets:delete(config_table)
        end,
        ets:new(config_table, [named_table, ordered_set]),
        ets:insert(config_table, Config),
        lists:foreach(fun({Node, _}) -> 
                ets:insert_new(node_load, {Node, 0}),
                ets:insert_new(node_stats, {Node, 0, 0, 0})
        end, Config),
        gen_server:cast(job_queue, schedule_job),
        {reply, ok, State};

% It is important that new_worker returns quickly. Job coordinator
% assumes that it can send all tasks to the server at once, which 
% must not take too long.
handle_call({new_worker, {JobName, PartID, Mode, PrefNode, Input}},
        {Pid, _}, State) ->
        
        Job = #job{jobname = JobName, partid = PartID, mode = Mode,
                    prefnode = PrefNode, input = Input, from = Pid},
        
        gen_server:cast(job_queue, {add_job, Job}),
        event_server:event(JobName, "~s:~B added to waitlist", [Mode, PartID], []),
        {reply, ok, State};

% The functions, node_busy(), choose_node(),
% start_worker() and handle_call(try_new_worker) handle task scheduling
% together with the job_queue server.
%
% The basic scheme is as follows:
%
% 0) A node becomes available, either due to a task finishing in
%    clean_worker() or a new node or slots being added at 
%    update_config_table().
%
% 1) job_queue server goes through its internal wait queue that includes all 
%    pending, not yet running tasks, and tries to get a task running, one by
%    one from the wait queue.
%
% 2) try_new_worker asks a preferred node from choose_node(). It may report
%    that all the nodes are 100% busy (busy) or that a suitable node could
%    not be found (all_bad). If all goes well, it returns a node name.
%
% 3) If a node name was returned, a new worker is started in start_worker().

handle_call({try_new_worker, Job}, _From, State) ->
        case choose_node(Job#job.prefnode) of
                busy -> {reply, {wait, busy}, State};
                {all_bad, BLen, ALen} when BLen == ALen ->
                        Job#job.from ! {master_error,
                                "Job failed on all available nodes"},
                        {reply, killed, State};
                {all_bad, _, _} -> {reply, {wait, all_bad}, State};
                Node -> {reply, start_worker(Job, Node), State}
        end;

handle_call({kill_job, JobName}, _From, State) ->
        event_server:event(JobName, "WARN: Job killed", [], []),
        lists:foreach(fun([Pid]) ->
                exit(Pid, kill_worker)
        end, ets:match(active_workers, {'$1', {'_', JobName, '_', '_', '_'}})),
        gen_server:cast(job_queue, {filter_queue, fun
                (Job) when Job#job.jobname == JobName  -> 
                        exit(Job#job.from, kill_worker),
                        false;
                (_) -> true
        end}),
        {reply, ok, State};

handle_call({clean_job, JobName}, From, State) ->
        handle_call({kill_job, JobName}, From, State),
        gen_server:cast(event_server, {clean_job, JobName}),
        {reply, ok, State};

handle_call({purge_job, JobName}, From, State) ->
        % SECURITY NOTE! This function leads to the following command
        % being executed:
        %
        % os:cmd("rm -Rf " ++ filename:join([Root, JobName]))
        %
        % Evidently, if JobName is not checked correctly, this function
        % can be used to remove any directory in the system. This function
        % is totally unsuitable for untrusted environments!

        C0 = string:chr(JobName, $.) + string:chr(JobName, $/),
        C1 = string:chr(JobName, $@),
        if C0 =/= 0 orelse C1 == 0 ->
                error_logger:warning_report(
                        {"Tried to purge an invalid job", JobName});
        true ->
                {ok, Root} = application:get_env(disco_root),
                handle_call({clean_job, JobName}, From, State),
                Nodes = [lists:flatten(["disco://", Node, "/", JobName]) ||
                        {Node, _} <- ets:tab2list(node_load)],
                garbage_collect:remove_job(Nodes),
                garbage_collect:remove_dir(filename:join([Root, JobName]))
        end,
        {reply, ok, State};


handle_call({blacklist, Node}, _From, State) ->
        event_server:event("[master]", "Node ~s blacklisted", [Node], []),
        ets:insert(blacklist, {Node, none}),
        {reply, ok, State};

handle_call({whitelist, Node}, _From, State) ->
        event_server:event("[master]", "Node ~s whitelisted", [Node], []),
        ets:delete(blacklist, Node),
        gen_server:cast(job_queue, schedule_job),
        {reply, ok, State};

handle_call(Msg, _From, State) ->
        error_logger:info_report(["Invalid call: ", Msg]),
        {reply, error, State}.

handle_cast({exit_worker, Pid, {ReplyType, Msg}}, State) ->
        clean_worker(Pid, ReplyType, Msg),
        {noreply, State}.

handle_info({'EXIT', Pid, Reason}, State) ->
        if Pid == self() -> 
                error_logger:info_report(["Disco server dies on error!", Reason]),
                {stop, stop_requested, State};
        Reason == normal -> {noreply, State};
        true -> 
                error_logger:info_report(["Worker killed", Pid]),
                case Reason of
                        {data_error, Input} -> clean_worker(Pid, data_error, 
                                {"Worker failure", Input});
                        kill_worker -> clean_worker(Pid, job_error, "");
                        _ -> clean_worker(Pid, error, Reason)
                end,
                {noreply, State}
        end;

handle_info(Msg, State) ->
        error_logger:info_report(["Unknown message received: ", Msg]),
        {noreply, State}.

% clean_worker() gets called whenever a disco_worker process dies, either
% normally or abnormally. Its main job is to remove the exiting worker
% from the active_workers table and to notify the corresponding job 
% coordinator about the worker's exit status.
clean_worker(Pid, ReplyType, Msg) ->
        {V, Nfo} = case ets:lookup(active_workers, Pid) of
                        [] -> {false, none};
                                %error_logger:info_report(["Unknown worker", Pid]),
                                %event_server:event("[master]",
                                %"WARN: Trying to clean an unknown worker",
                                %        [], []),
                        R -> {true, R}
                   end,
        if V ->
                [{_, {From, _JobName, Node, _Mode, PartID}}] = Nfo,
                update_stats(Node, ReplyType),
                ets:delete(active_workers, Pid),
                ets:update_counter(node_load, Node, -1),
                From ! {ReplyType, Msg, {Node, PartID}},
                gen_server:cast(job_queue, schedule_job);
                %schedule_waiter(WaitQueue, []);
        true -> ok
        end.

update_stats(Node, job_ok) -> ets:update_counter(node_stats, Node, {2, 1});
update_stats(Node, data_error) -> ets:update_counter(node_stats, Node, {3, 1});
update_stats(Node, job_error) -> ets:update_counter(node_stats, Node, {4, 1});
update_stats(Node, error) -> ets:update_counter(node_stats, Node, {4, 1});
update_stats(_Node, _) -> ok.


node_busy(_, []) -> true;
node_busy([{_, Load}], [{_, MaxLoad}]) -> Load >= MaxLoad.

choose_node({PrefNode, TaskBlackNodes}) ->

        % From non-busy nodes, remove the ones that have already
        % failed this task (TaskBlackNodes) or that are globally
        % blacklisted (ets-table blacklist).
        BlackNodes = TaskBlackNodes ++ 
                [X || [X] <- ets:match(blacklist, {'$1', '_'})],
        
        % Is our preferred choice available?
        PrefBusy = node_busy(ets:lookup(node_load, PrefNode),
                         ets:lookup(config_table, PrefNode)),

        % Is our preferred choice blacklisted?
        PrefBlack = lists:member(PrefNode, BlackNodes),

        if PrefBlack; PrefBusy ->
                % If not, start with all configured nodes..
                AllNodes = ets:tab2list(node_load),

                % ..and choose the ones that are not 100% busy.
                AvailableNodes = lists:filter(fun({Node, _Load} = X) -> 
                        not node_busy([X], ets:lookup(config_table, Node))
                end, AllNodes),

                AllowedNodes = lists:filter(fun({Node, _Load}) ->
                        not lists:member(Node, BlackNodes)
                end, AvailableNodes),
                
                if length(AvailableNodes) == 0 -> busy;
                length(AllowedNodes) == 0 -> 
                        {all_bad, length(TaskBlackNodes), length(AllNodes)};
                true -> 
                        % Pick the node with the lowest load.
                        [{Node, _}|_] = lists:keysort(2, AllowedNodes),
                        Node
                end;
        true ->
                % If yes, return the preferred node.
                PrefNode
        end.

start_worker(J, Node) ->
        event_server:event(J#job.jobname, "~s:~B assigned to ~s",
                [J#job.mode, J#job.partid, Node], []),
        ets:update_counter(node_load, Node, 1),
        spawn_link(disco_worker, start_link_remote, 
                [[self(), whereis(event_server), J#job.from, 
                J#job.jobname, J#job.partid, J#job.mode, Node, J#job.input]]),
        ok.

% slave:start() contains a race condition, thus it is not safe to call it
% simultaneously in many parallel processes. Instead, we serialize the calls
% through slave_master().
slave_master(SlaveName) ->
        receive
                {start, Pid, Node, Args} ->
                        R = case application:get_env(disco_slaves_os) of
                                {ok, "osx"} ->
                                        slave:start(list_to_atom(Node),
                                                SlaveName, Args, self(),
                                                "/usr/libexec/StartupItemContext erl");
                                _ ->
                                        slave:start_link(list_to_atom(Node),
                                                SlaveName, Args)
                        end,
                        Pid ! slave_started,
                        error_logger:info_report(["New slave at ", Node, R]),
                        slave_master(SlaveName)
        end.                       

% callback stubs
terminate(_Reason, _State) -> {}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

