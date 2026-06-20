#!/bin/bash

# cd "$(dirname "$0")/prototypes/hgs_surrealdb_sdk"

SESSION="surrealdb"
CONTAINER_NAME="${SURREAL_CONTAINER_NAME:-surrealdb_local}"

# Create a new detached session named "surrealdb"
tmux new-session -d -s "$SESSION" -n surrealdb "docker logs -f --tail 200 $CONTAINER_NAME"

# tmux rename-window
tmux rename-window -t "$SESSION:0" 'surrealdb'

tmux new-window -t "$SESSION:1" -n 'surrealdb-sql' 'surreal sql --endpoint http://localhost:8000 --username root --password root'

tmux new-window -t "$SESSION:2" -n 'iex' 'iex -S mix'

tmux new-window -t "$SESSION:3" -n 'hermes' 'hermes'

tmux new-window -t "$SESSION:4" -n 'zsh' 'zsh'

# Attach to the session
tmux select-window -t "$SESSION:3"
tmux attach-session -t "$SESSION"

# cd ..
