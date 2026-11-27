/* Copyright (c) 2001 Matej Pfajfar.
 * Copyright (c) 2001-2004, Roger Dingledine.
 * Copyright (c) 2004-2006, Roger Dingledine, Nick Mathewson.
 * Copyright (c) 2007-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

/**
 * \file tor_api.h
 * \brief Public C API for the Tor network service.
 *
 * Vendored from tor.xcframework 409.17.1 (feature/api/tor_api.h) so the
 * TorSupport package does not depend on headers inside the binary framework.
 **/

#ifndef TOR_API_H
#define TOR_API_H

typedef struct tor_main_configuration_t tor_main_configuration_t;

/**
 * Create and return a new tor_main_configuration().
 */
tor_main_configuration_t *tor_main_configuration_new(void);

/**
 * Set the command-line arguments in <b>cfg</b>.
 *
 * The <b>argc</b> and <b>argv</b> values here are as for main().  The
 * contents of the argv pointer must remain unchanged until tor_run_main() has
 * finished and you call tor_main_configuration_free().
 *
 * Return 0 on success, -1 on failure.
 */
int tor_main_configuration_set_command_line(tor_main_configuration_t *cfg,
                                            int argc, char *argv[]);

#ifdef _WIN32
typedef SOCKET tor_control_socket_t;
#define INVALID_TOR_CONTROL_SOCKET INVALID_SOCKET
#else
typedef int tor_control_socket_t;
#define INVALID_TOR_CONTROL_SOCKET (-1)
#endif /* defined(_WIN32) */

/** DOCDOC */
tor_control_socket_t tor_main_configuration_setup_control_socket(
                                          tor_main_configuration_t *cfg);

/**
 * Release all storage held in <b>cfg</b>.
 */
void tor_main_configuration_free(tor_main_configuration_t *cfg);

/**
 * Return the name and version of the software implementing the tor_api
 * functionality.
 */
const char *tor_api_get_provider_version(void);

/**
 * Run the tor process, as if from the command line.
 *
 * This function will not return until Tor is done running. It returns zero
 * on success, and nonzero on failure.
 */
int tor_run_main(const tor_main_configuration_t *);

/**
 * Run the tor process, as if from the command line.
 *
 * @deprecated Using this function from outside Tor is deprecated; you should
 * use tor_run_main() instead.
 */
int tor_main(int argc, char **argv);

#endif /* !defined(TOR_API_H) */
