# tmux-sec-test

Some tests and script to secure tmux servers on shared servers

Prerequisites : none, except tmux and standard shell tools.

Setup for testing :

- run `test/prepare.sh` as `root`

Setup for securing :

- run `secure.sh` as `root`, *for example in a cron job*
- possible options : `--dry-run` and `--debug

See `# What does the securing script do ?` to learn what the script does.

# tmux versions

tmux changelog : https://github.com/tmux/tmux/blob/master/CHANGES

version <3.3 (debian 11 bullseye)

- server socket created with `660` permissions
- no `server-access` feature

version >=3.3 (debian 12 bookworm)

- server socket created with `600` permissions
- `server-access` feature available, with only owner allowed at first

# how to share a tmux server

NOTE: tmux servers can be shared only locally on a single multi-user host 

version <3.3 (debian 11 bullseye):

- owner creates a session using `tmux -S /path/to/socket`
- allow `group` or `other` to write to the socket
- allow `group` or `other` to reach the socket (execute on folder path)
- another user attaches to the peer session : `tmux -S /path/to/socket attach`

version >=3.3 (debian 12 bookworm):

- **do the same as above**
- **and** allow *another named users* to connect to the socket *to view only*
  - `tmux -S /path/to/socket server-access -a -r another`
- to let the other user type and use all tmux features with you :
  - remove the `-r` option in the above command

See https://man7.org/linux/man-pages/man1/tmux.1.html and search for `server-access` for version 3.3+

# how to secure tmux servers processes

application-side (v3.3+) :

- only the owner user is allowed to connect to the socket by default
- so to secure, cleanup the allowed users and detached connected users which are not the owners

filesystem-side :

- **either** the socket is not reachable for *group* **and** *others*
  - the folders of the path to root must not have execute bits set
  - any one of the folder, for each permission, as long as there is one for each
- **or** the socket itself should not be writable for the *group* **and** *others*
  - read permissions do not matter, as you cannot read answers without writing requests

# What does the securing script do ?

Only the bare minimum to secure the sessions without disrupting the host processes :

- checks for tmux availability
- lists all tmux processes (client and server)
  - asks for re-creation of the server sockets though pid
  - lists sockets and their inodes using /proc from pid
  - locates absolute unix socket using /proc and current working directory of pid
- for each server socket
  - gets tmux server pid through socket
  - gets tmux server owner from /proc and pid
  - detaches any present user, which is not the owner of the server
  - tests tmux version to check for `server-access` command availability
    - denies any present user, which is not the owner of the server
  - checks the folder path to root leading to the socket
    - if any folder has group execute and if any folder has other execute
      - checks the socket for group and others write permissions
        - clears the write permissions for group and others, if present
