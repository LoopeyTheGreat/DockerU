the idea here is to create wrapper for docker commsnds whuch automically specifies the correct docker daemon user in roitless, multi daemon focker systemsc We should have a configuration file where we set the uuid associated with a servicec The values can be pre-populated using the uuid registry in dht-standards, but we should allow uodating either viamanual edits, or updating via ansible/ansible-pull. Id like this to autom`tically re-write the command to include sudo-u {daemon uix} c So for example:

current / manual command:  sudo -u {daemon_user} docker {command}
new command: dockeru {command}
wrapper passes: sudo -u {daemon_user or darmon_uid} docker {command}

 The dockerls command should work for docker, docker compose, docker exec  `nd any other docker commands

 esentially- dockeru automatically converts command to sudo -u {daemon_user}

 things to consider- first we will  gather a list if all docker container names associated with the servicev so the command dockeru nextcloud restart  will convert to sudo dockeru. Im thinkong this should be done dynamically so that new container names added to the service land in the dockeru registry. Im open to `nother approach, the workflow i imagine:

 dockeru.conf kreps a list of docker daemon users and services. The formatting should be fairly easy to configure and also update manually or automatically
 
 daemon-user: docker-nextcloud
 uid: 1101
 containers: 
    nexctcloud
    coloabra
    cloud_puller

daemon-user: docker-immich_pridm
uid: 1102
containers:
    immich
    photoprism
    album_sync


excluded container names:
    komodo
    portainer


Excluded container names are container names th`t apoear in more than one servuce.  This should be auti generated in any additions or uodates.

All feilds except daemon-user should be auto populatedv or manually set.
Some seitches id like:

*** warn to run with sudo to modify base config for all users kocated in /etc, oterwise we are addressing the users config in ~/.dockeru

dockeru --add = add new daemon user with interactive setup- allow manual or automatic additions of all or some detected docker users
dockeru --add {daemon_user} = add user automatically with confirmstion prompt inly
dockeru --list = list all services/containers
dockeru --list {daemon_user} = list all container names associated with that daemon
dockeru --refresh = interactive refrrsh of containers in configured daemons (up/doen listv with all option at the top) - prompt with confirmation on additions, and on rrmovals
dockeru --refresh {daemon_user} non interactive refresh of daemon, with summary confirnation before finalizing
dockeru --remove =interactive removal wuth up/down menu
dockeru --remove {daemon_user} = non interactive removal of selected daemonv still needs confirmation
dockeru --help = display help

dockeru ls = docker ps of all configured daemon users

Other thoughts:
document throughly this will be a public repo
consuder edge case usesv again public repo. 
support tab autofill for daemon_users
always check for and alert on identical/existing container names, auto add to excluded container names after alerting
when we refresh or add a daemon_userv remind user to make sure all containers have been built/added or  are running for auto-config to work (we use docker ps to find containers - we will use all containers found, not just ones running)
installer should:
- ibstall for current user, all users, or some users- use up/dow selection menu
- detect user(s) that dont have nopassword sudo and offer to add nopassword sudo- but do warn about security risks if doing si
- have a uninstall/remove function for one, somev or all users
- add dockeru to $PATH 
- disolay the readme post-install , instruct user where to find config fikes
- lets keep the default config in /etc/dockeru  , but also allow for an additional config in ~/.dockeru



