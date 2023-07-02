# Host bootstrapping

## Initial bootstrapping

Run this on the LXC parent:

```
prepare-container.sh <CONTAINER_ID>
```

Example:

```
prepare-container.sh 101
```

## Ansible usage

### Sample inventory

```
[ai_hosts]
ai1
ai2

[storage_hosts]
storage1
storage2
```

### Listing all hosts

```
ansible all --list-hosts
```

### Executing playbooks

```
ansible-playbook playbook.yml
```

### Running commands

```
ansible <group> -a "<command>"
```

Example:

```
ansible ai_hosts -a "ls -la"
```

### Running modules

```
ansible <group> -m <module>
```

Some useful modules:

| Module  | Example                                                              | Description                         |
|---------|----------------------------------------------------------------------|-------------------------------------|
| apt     | `ansible myhosts -m apt -a "name=vim"`                               | Install the given package using apt |
| service | `ansible your_hosts -m service -a "name=your_service state=started"` | control the state of a service      |
