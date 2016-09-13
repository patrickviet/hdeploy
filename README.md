HDeploy handbook
================

HDeploy is a deployment framework that uses the concept of artifacts. This handbook covers practical uses.

Deployment workflow
-------------------

Here is the outline
1. Build artifact (on a build server)
2. Distribute artifact (on servers)
3. "Activate" artifact (on servers), also known as symlink.

The way that HDeploy works is similar to Chef and other configuration management: on one side, you have a desired state (which artifacts should be where, activate, etc), stored in a registry, and on the other side, you have the actual servers, on which you run the *hdeploy_node* daemon, which is in charge with making the desired state consistent with reality, and reporting that reality back.

SSH Setup so you can use the build server
-----------------------------------------

There are several ways to proceed. Here I'll describe the "ssh forward" way.

You need to put your ssh private key in memory, with the ssh agent. Consequently, steps 1 and 2 need to be repeated after each reboot of your workstation.

1. You need ssh-agent running on your Mac/Linux computer. To check if it's running, type ```ps -ef  | grep ssh-agent```. If it's not running, just run ```ssh-agent```
2. You need your private key added to the ssh-agent: ```ssh-add ~/.ssh/id_rsa``` (you can check it's there with just ```ssh-add```

3. Configure the file ```~/.ssh/config``` to forward your key, with this directive:
```
Host *.gyg.io
   ForwardAgent yes
```

Now you can test your forwarding:
```ssh build.gyg.io```

and from build.gyg.io: ```ssh web1.gyg.io```

Note: the ssh to web1 is **only** to test if forwarding works. All operations should be run from build server

If it worked, you're set to use the HDeploy CLI tool.

Please first initialise things with ```hdeploy initrepo``` on the build server.


HDeploy CLI tool
----------------

This is what you are going to use to make things happen
All operations should be run on the build server.

- ```hdeploy state``` shows you the current artifacts.
- ```hdeploy env:<env>``` sets environment, ie. ```hdeploy env:production```
- ```hdeploy distribute:<artifact>``` will distribute an artifact in an environment

You can (and have to) chain commands to make things happen. For example, if you want to distribute artifact *gyg.123.master* to production, you will type this:

```hdeploy env:production distribute:gyg.123.master```

And if you want to then symlink it, ```hdeploy env:production symlink:gyg.123.master```

Example full life cycle process
-------------------------------

```hdeploy build:THack```
Will take 5min to build artifact for branch THack.

Let's say it is called ```gyg.20150223_15_35_18.THack.09775e8711b8```

Now we want to test it
- ```hdeploy env:test distribute:gyg.20150223_15_35_18.THack.09775e8711b8```
- ```hdeploy env:test symlink:gyg.20150223_15_35_18.THack.09775e8711b8```

That worked.
Next step, you want to push it to production

- ```hdeploy env:production distribute:gyg.20150223_15_35_18.THack.09775e8711b8```
- ```hdeploy env:production symlink:gyg.20150223_15_35_18.THack.09775e8711b8```

And... That's it.

If you want to rollback: ```hdeploy env:production symlink:<name of other artifact>``` (remember, you can see that with ```hdeploy state```)

If something didn't fully roll out for whatever reason (say, network failure) you can just re-do it. ```hdeploy env:production distribute:<artifact name>``` will redo a force distribute, regardless of if the artifact was already there or not. Same for command symlink etc.




Configuration documentation
---------------------------

```json
{
  "api": { // used by every element - they all access the API
    "http_user": "someuser", // required
    "http_password": "somepassword", // required
    "endpoint": "http://somefqdn:port/" // required
  },
  "node": { // just required by the node
    "keepalive_delay": 60, // defaults to 60
    "check_deploy_delay": 60, // default to 60
    "max_run_duration": 3600, // default to 1 hr
    "hostname":"somefqdn" // defaults to fqdn
  },
  "build": { // required on the build server. You don't even need a build server
    "nameofapp": {
      "git": "git@github.com:organization/repo", // required
      "subdir": "", // default value
      "prune": 5, // default value
      "repo_dir": "~/build/repos/nameofapp", // this will default to this
      "build_dir": "~/build/build/nameofapp", // this will default to this too
      "artifact_repo": "nameofrepo" // will default to 'default'

    }
  },
  "artifact_repo": { // just on the build server. you could actually build on jenkins, issue an API command and never use this
    "nameofrepo": {
      "type":"local", // required
      "path":"/home/artifacts" // required for local
      "url_pattern":"http://localhost:8502/%{filename}" // required for local
    }
  },
  "deploy": { // required on node
    "nameofapp:env": { // you need the environment. It's originally coupled with chef but actually you can do whatever you want
      "symlink": "/var/www/nameofapp/current", // required
      "relpath": "/var/www/nameofapp/releases", // will default to symlink/../releases
      "tgzpath": "/var/www/nameofapp/tarballs", // will default to symlink/../tarballs
      "user": "appuser", // will default to www-data (33)
      "group": "appgroup" // will default to www-data (33)

      "active": true // defaults to false. this allows to define all deploys in config but only activate them selectively
    }
  },
  "cli": { 
    "fab": "/opt/hdeploy/embedded/bin/fab", // will default to this
    "default_app":"nameofapp", // if not set, the cli will scream if you don't specify an app
    "domain_name":"mydomain.com" // will default to nothing. you'
  }
}

```

If you use the Chef recipe, and the LWRPs, you'll get a bonus syntax check for everything
