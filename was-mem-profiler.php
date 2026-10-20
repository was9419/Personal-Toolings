<?php
/**
 * Plugin Name: Kinsta Temporary Memory Profiler
 * Description: Logs requests whose peak memory goes above 60% of the PHP memory limit. TEMPORARY: delete after diagnosis.
 *
 * Log file: /www/<site>/private/kinsta-mem-profile.log (outside the public web root).
 * Format:   timestamp <TAB> peakMB/limitMB <TAB> METHOD /path <TAB> ajax/REST action (if any)
 */

add_action( 'shutdown', function () {
	if ( PHP_SAPI === 'cli' ) {
		return;
	}

	$limit = wp_convert_hr_to_bytes( ini_get( 'memory_limit' ) );
	$peak  = memory_get_peak_usage( true );

	if ( $limit <= 0 || $peak < $limit * 0.6 ) {
		return;
	}

	$dir = dirname( untrailingslashit( ABSPATH ) ) . '/private';
	if ( ! is_dir( $dir ) || ! is_writable( $dir ) ) {
		return;
	}

	$action = isset( $_REQUEST['action'] ) ? sanitize_key( wp_unslash( $_REQUEST['action'] ) ) : '';
	$uri    = isset( $_SERVER['REQUEST_URI'] ) ? strtok( wp_unslash( $_SERVER['REQUEST_URI'] ), '?' ) : '';
	$method = isset( $_SERVER['REQUEST_METHOD'] ) ? sanitize_key( $_SERVER['REQUEST_METHOD'] ) : '';

	$line = sprintf(
		"%s\t%dMB/%dMB\t%s %s\t%s\n",
		gmdate( 'c' ),
		$peak / 1048576,
		$limit / 1048576,
		strtoupper( $method ),
		$uri,
		$action
	);

	@file_put_contents( $dir . '/kinsta-mem-profile.log', $line, FILE_APPEND | LOCK_EX );
}, PHP_INT_MAX );
