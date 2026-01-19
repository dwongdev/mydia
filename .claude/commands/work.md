---
argument-hint: <task-id>
description: Start working on a backlog task and its sub-tasks
---

# Work on Backlog Task

You are now starting work on backlog task **$1**.

## Instructions

### Phase 1: Deep Context Gathering

1. **Fetch the task details**

   - Use `mcp__backlog__task_view` with id "$1" to get complete task information
   - Review the task title, description, status, priority, and labels
   - Check for implementation plan/notes if they exist
   - Review acceptance criteria (these are often sub-tasks to complete)
   - Note any dependencies listed

2. **Check for subtasks (CRITICAL)**

   - Use `mcp__backlog__task_list` with search="$1" to find all subtasks
   - Subtasks are identified by IDs like "$1.1", "$1.2", "$1.3", etc.
   - Review the status of each subtask to get the big picture:
     - "Done" - Already completed, skip
     - "In Progress" - Continue working on this one
     - "To Do" - Next subtask to work on
   - **If subtasks exist, work on them in order rather than the parent task**
   - Only mark the parent task as "Done" when ALL subtasks are complete

3. **Build comprehensive understanding (SPAWN AGENTS)**

   Use the Task tool with `subagent_type="Explore"` to gather deep context. You SHOULD spawn multiple exploration agents in parallel to understand:

   - **Architecture context**: How does this task fit into the overall system? What modules/components are involved?
   - **Existing patterns**: What similar implementations exist in the codebase? How are they structured?
   - **Dependencies**: What code will this task interact with? What are the interfaces?
   - **Test patterns**: How are similar features tested? What test utilities exist?

   Example parallel exploration:
   ```
   Agent 1: "Find all existing implementations similar to [task topic] and document the patterns used"
   Agent 2: "Map the module dependencies and interfaces that will be affected by [task]"
   Agent 3: "Find test patterns and utilities used for similar features"
   ```

   **IMPORTANT**: These agents are for RESEARCH ONLY. They must NEVER write code - only gather information and report back.

4. **Synthesize high-level overview**

   After gathering context, create a clear mental model:
   - What is the goal of this task at a high level?
   - What are the key technical decisions?
   - What are the integration points?
   - What risks or complications exist?

### Phase 2: Planning

5. **Create a work plan**

   - Use the TodoWrite tool to create a structured task list
   - Break down the work into small, testable increments
   - Include each acceptance criterion as a separate todo item
   - Plan to update task status as you progress
   - **Ensure each todo item represents COMPLETE, PRODUCTION-READY work** - not stubs or placeholders

6. **Update task status**

   - If working on a subtask, set the subtask status to "In Progress"
   - If the parent task is not yet "In Progress", update it as well
   - Add your name to the assignee list if not already there

### Phase 3: Execution

7. **Execute the work**

   - Follow the development guidelines in CLAUDE.md
   - Work incrementally with frequent commits
   - Run tests after each significant change
   - Update the task's implementation notes as you discover important details
   - Check off acceptance criteria as you complete them using `mcp__backlog__task_edit`

8. **Handle blockers and scope expansion**

   - If you encounter issues, update the task's implementation notes
   - If you get stuck after 3 attempts, document what failed and ask the user
   - **If you discover work that cannot be completed in this session, you MUST create subtasks** - never leave stubs

### Phase 4: Completion and Continuation

9. **Verify subtask completeness (CRITICAL - NO STUBS ALLOWED)**

   Before marking any subtask complete, verify:
   - [ ] All code is PRODUCTION-READY - no `TODO`, `FIXME`, placeholder implementations, or demo code
   - [ ] All functions have real implementations, not stubs that return hardcoded values
   - [ ] No "coming soon" or "not yet implemented" comments left behind
   - [ ] All error handling is real, not placeholder `raise "not implemented"`
   - [ ] Tests cover actual behavior, not just placeholder assertions

   **If any work remains incomplete:**
   - Use `mcp__backlog__task_create` to create subtasks for the remaining work
   - Link them to the parent task using `parentTaskId`
   - Document clearly what was completed vs what remains
   - **DO NOT mark the parent task as Done until all work is complete**

10. **Mark subtask complete and CONTINUE TO NEXT (CRITICAL)**

    After completing a subtask:
    - Mark the subtask status as "Done" using `mcp__backlog__task_edit`
    - Add brief completion notes
    - **IMMEDIATELY check for remaining subtasks** using `mcp__backlog__task_list` with search="$1"
    - **If more subtasks remain with status "To Do", continue working on the next one**
    - Loop back to Phase 1 step 3 (context gathering) for the next subtask
    - Much of the context from previous subtasks will still be relevant - leverage it

    **DO NOT STOP after completing one subtask if:**
    - There are more subtasks remaining
    - You still have context available
    - The conversation has not been interrupted

    **Only stop working when:**
    - All subtasks are marked "Done"
    - You're running low on context (conversation getting very long)
    - You encounter a blocker that requires user input
    - The user interrupts or redirects you

11. **Propose improvements (after all subtasks or when stopping)**

    After completing work on subtasks, reflect on what you learned:
    - Are there patterns that could be extracted for reuse?
    - Did you discover technical debt that should be addressed?
    - Are there optimizations or enhancements that would improve the implementation?
    - Would documentation help future developers?

    If improvements are warranted, create new backlog tasks with:
    - Clear description of the improvement
    - Context from the work just completed
    - Priority suggestion based on impact

12. **Complete the parent task (only when ALL subtasks are done)**

    - Verify ALL subtasks have status "Done"
    - Ensure all acceptance criteria on the parent are checked off
    - Run the full test suite and precommit checks
    - Update the parent task status to "Done" using `mcp__backlog__task_edit`
    - Add completion notes documenting:
      - Summary of all subtasks completed
      - Key technical decisions made
      - Any improvement tasks created
    - If any subtasks remain incomplete, leave the parent as "In Progress"

## Critical Rules

### Maximize subtask throughput - work until context runs out

Your goal is to complete as many subtasks as possible in a single session. After completing each subtask:

1. **Immediately check for more subtasks** - don't wait for the user to ask
2. **Continue to the next "To Do" subtask** - leverage the context you've already built
3. **Only stop when necessary** - all done, blocked, or context exhausted

This is critical because:
- Context switching between sessions is expensive
- You already have the codebase patterns loaded in context
- The user initiated `/work` expecting maximum progress
- Completing more subtasks in one session = faster overall delivery

**Signs you should keep going:**
- You just completed a subtask successfully
- There are more subtasks with status "To Do"
- You haven't hit any blockers
- The conversation isn't extremely long yet

**Signs you should stop:**
- All subtasks are "Done"
- You need user input to proceed
- You've hit a blocker after 3 attempts
- Context is clearly exhausted (very long conversation, losing track of details)

### NEVER leave code in a stubbed or demo state

This is the most important rule. If you cannot complete something fully:

1. **Create a subtask** for the incomplete work using `mcp__backlog__task_create`
2. **Document clearly** what is done vs what remains
3. **Remove or clearly mark** any temporary/placeholder code
4. **Do not mark the task as Done** - leave it In Progress or create subtasks

Examples of FORBIDDEN states:
- Functions that return hardcoded values instead of real logic
- Comments like `// TODO: implement this`
- Error handlers that just log and continue
- Tests that assert `true` or skip real assertions
- Partial implementations that only handle the happy path

### Use agents for research, NEVER for coding

You may spawn exploration agents freely to:
- Understand codebase patterns
- Find related implementations
- Map dependencies
- Gather context

You must NEVER spawn agents to:
- Write code
- Make edits
- Create files
- Run commands that modify state

All code changes must be made directly by you in the main conversation.

## Important Reminders

- Always read the task details FIRST before starting any work
- Spawn exploration agents to build deep understanding before coding
- Keep the task status updated as you progress
- Use acceptance criteria as your checklist for completion
- Document blockers and decisions in the task's implementation notes
- Create subtasks for any work you cannot complete - never leave stubs
- Propose improvements based on insights gained during implementation
- Don't mark the task as done until ALL acceptance criteria are met AND all code is production-ready
- **After completing each subtask, immediately continue to the next one** - maximize throughput while you have context
- **Only stop when all subtasks are done, you're blocked, or context is exhausted** - the user expects maximum progress per session
