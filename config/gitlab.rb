# External URL for accessing GitLab
external_url 'http://gitlab-infra.apps.itz-j3yfm1.hub04-lb.techzone.ibm.com'

# Nginx settings
nginx['enable'] = true
nginx['redirect_http_to_https'] = false  # As specified in values.yaml
nginx['listen_https'] = false  # As specified in values.yaml

# GitLab webservice settings
gitlab_rails['gitlab_shell_ssh_port'] = 0
gitlab_shell['enable'] = false
gitlab_rails['webservice_external_port'] = 80
gitlab_rails['gitlab_shell_ssh_path'] = '/bin/false'
gitlab_rails['ssh_host_rsa_key'] = '/dev/null'
gitlab_rails['ssh_host_dss_key'] = '/dev/null'
gitlab_rails['ssh_host_ecdsa_key'] = '/dev/null'
gitlab_rails['ssh_host_ed25519_key'] = '/dev/null'
# Prevent runit from symlinking SSHD services (extra hardening)
runit['svlogd_bin'] = '/bin/false'
runit['chpst_bin'] = '/bin/false'
gitlab_rails['security_context'] = {
  'runAsUser' => 1000,
  'runAsGroup' => 1000,
  'fsGroup' => 1000
}


openssh['enable'] = false
service['sshd'] = false



# Gitaly settings for persistence
gitaly['persistence'] = true
gitaly['storage_class'] = 'standard'  # Adjust based on your PVC setup
gitaly['security_context'] = {
  'runAsUser' => 1000,
  'runAsGroup' => 1000,
  'fsGroup' => 1000
}

# GitLab Shell settings
gitlab_shell['service'] = {
  'securityContext' => {
    'runAsUser' => 1000,
    'runAsGroup' => 1000,
    'fsGroup' => 1000
  }
}

# Redis settings
redis['enable'] = true
redis['master']['enable'] = true
redis['replica']['enable'] = false

# Disable internal PostgreSQL and connect to external PostgreSQL
postgresql['enable'] = false  # Disable internal database

# GitLab PostgreSQL connection settings
gitlab_rails['db_adapter'] = 'postgresql'
gitlab_rails['db_host'] = 'gitlab-postgresql'  # The name of your external PostgreSQL service
gitlab_rails['db_port'] = 5432
gitlab_rails['db_username'] = 'gitlab'
gitlab_rails['db_password'] = 'gitlab'  # This should match the PostgreSQL password
gitlab_rails['db_database'] = 'gitlab'

# Prometheus settings
prometheus['enable'] = false  # As per your `values.yaml`

# Registry settings
registry['enable'] = false  # Disable the registry
