local memcached = import 'memcached/memcached.libsonnet';

memcached {
  local statefulSet = $.apps.v1.statefulSet,
  local service = $.core.v1.service,
  local container = $.core.v1.container,
  local mount = $.core.v1.volumeMount,
  local volume = $.core.v1.volume,

  memcached+:: {
    cpu_limits:: null,
    deployment: {},
    statefulSet:
      statefulSet.new(self.name, 3, [
        self.memcached_container,
        self.memcached_exporter,
      ], []) +
      statefulSet.mixin.spec.withServiceName(self.name) +
      (if !std.isObject($._config.node_selector) then {} else statefulSet.mixin.spec.template.spec.withNodeSelectorMixin($._config.node_selector)) +
      $.util.antiAffinity,

    service:
      $.util.serviceFor(self.statefulSet) +
      service.mixin.spec.withClusterIp('None'),
  },

  // Optionally configure Memcached to use mTLS for authenticating clients
  memcached_mtls:: {
    // CA and server credentials
    statefulSet+: statefulSet.mixin.spec.template.spec.withVolumesMixin([
      volume.fromSecret($._config.memcached_mtls_ca_cert_secret, $._config.memcached_mtls_ca_cert_secret),
      volume.fromSecret($._config.memcached_mtls_server_cert_secret, $._config.memcached_mtls_server_cert_secret),
      volume.fromSecret($._config.memcached_mtls_server_key_secret, $._config.memcached_mtls_server_key_secret),
    ]),

    // Increase requested CPU, mount the credentials, and adjust server config
    memcached_container+: $.util.resourcesRequestsMixin('1', null) + container.withVolumeMountsMixin([
      mount.new($._config.memcached_mtls_ca_cert_secret, $._config.memcached_ca_cert_path, true),
      mount.new($._config.memcached_mtls_server_cert_secret, $._config.memcached_server_cert_path, true),
      mount.new($._config.memcached_mtls_server_key_secret, $._config.memcached_server_key_path, true),
    ]) + container.withArgsMixin([
      '--listen=notls:127.0.0.1:11211,0.0.0.0:11212',  // No TLS on the local interface for the exporter and debugging
      '--enable-ssl',
      '--extended=' +
      'ssl_ca_cert=' + $._config.memcached_ca_cert_path + $._config.memcached_mtls_ca_cert_secret + '.pem,' +
      'ssl_chain_cert=' + $._config.memcached_server_cert_path + $._config.memcached_mtls_server_cert_secret + '.pem,' +
      'ssl_key=' + $._config.memcached_server_key_path + $._config.memcached_mtls_server_key_secret + '.pem,' +
      'ssl_kernel_tls,ssl_verify_mode=2',  // "2" means "require client cert"
    ]),
  },

  // Dedicated memcached instance used to cache query results.
  memcached_frontend: if $._config.memcached_frontend_enabled then
    $.memcached {
      name: 'memcached-frontend',
      max_item_size: '%dm' % [$._config.memcached_frontend_max_item_size_mb],
      connection_limit: 16384,
    } + if $._config.memcached_frontend_mtls_enabled then $.memcached_mtls else {}
  else {},

  // Dedicated memcached instance used to temporarily cache index lookups.
  memcached_index_queries: if $._config.memcached_index_queries_enabled then
    $.memcached {
      name: 'memcached-index-queries',
      max_item_size: '%dm' % [$._config.memcached_index_queries_max_item_size_mb],
      connection_limit: 16384,
    } + if $._config.memcached_index_queries_mtls_enabled then $.memcached_mtls else {}
  else {},

  // Memcached instance used to cache chunks.
  memcached_chunks: if $._config.memcached_chunks_enabled then
    $.memcached {
      name: 'memcached',
      max_item_size: '%dm' % [$._config.memcached_chunks_max_item_size_mb],

      // Save memory by more tightly provisioning memcached chunks.
      memory_limit_mb: 6 * 1024,
      overprovision_factor: 1.05,
      connection_limit: 16384,
    } + if $._config.memcached_chunks_mtls_enabled then $.memcached_mtls else {}
  else {},

  // Memcached instance for caching TSDB blocks metadata (meta.json files, deletion marks, list of users and blocks).
  memcached_metadata: if $._config.memcached_metadata_enabled then
    $.memcached {
      name: 'memcached-metadata',
      max_item_size: '%dm' % [$._config.memcached_metadata_max_item_size_mb],
      connection_limit: 16384,

      // Metadata cache doesn't need much memory.
      memory_limit_mb: 512,

      statefulSet+:
        statefulSet.mixin.spec.withReplicas(1),
    } + if $._config.memcached_metadata_mtls_enabled then $.memcached_mtls else {}
  else {},
}
