/**
 * @file
 * @brief SMTP client library header.
 * @author James Humphrey (mail@somnisoft.com)
 * @version 1.00
 *
 * This SMTP client library allows the user to send emails to an SMTP server.
 * The user can include custom headers and MIME attachments.
 *
 * This software has been placed into the public domain using CC0.
 */

#ifndef SMTP_H
#define SMTP_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdio.h>
#include <stddef.h>

/* ============================================================
 * Connection Security
 * ============================================================ */
enum smtp_connection_security {
  SMTP_SECURITY_NOTSET,
  SMTP_SECURITY_TLS,
  SMTP_SECURITY_STARTTLS,
};

/* ============================================================
 * Authentication Method
 * ============================================================ */
enum smtp_authentication_method {
  SMTP_AUTH_NONE,
  SMTP_AUTH_PLAIN,
  SMTP_AUTH_LOGIN,
  SMTP_AUTH_CRAM_MD5,
};

/* ============================================================
 * Address Type
 * ============================================================ */
enum smtp_address_type {
  SMTP_ADDRESS_FROM,
  SMTP_ADDRESS_TO,
  SMTP_ADDRESS_CC,
  SMTP_ADDRESS_BCC,
};

/* ============================================================
 * Status Codes (public API return values)
 * ============================================================ */
enum smtp_status_code {
  SMTP_STATUS_OK,
  SMTP_STATUS_NOMEM,
  SMTP_STATUS_CONNECT,
  SMTP_STATUS_HANDSHAKE,
  SMTP_STATUS_AUTH,
  SMTP_STATUS_SEND,
  SMTP_STATUS_RECV,
  SMTP_STATUS_CLOSE,
  SMTP_STATUS_SERVER_RESPONSE,
  SMTP_STATUS_PARAM,
  SMTP_STATUS_FILE,
  SMTP_STATUS_DATE,
  SMTP_STATUS__LAST,
};

/* ============================================================
 * Flags
 * ============================================================ */
enum smtp_flag {
  SMTP_FLAG_NONE = 0,
  SMTP_DEBUG = (1 << 0),
  SMTP_NO_CERT_VERIFY = (1 << 1),
};

#define SMTP_FLAG_INVALID_MEMORY (enum smtp_flag)(0xFFFFFFFF)

struct smtp;

/* ============================================================
 * Internal types (only when compiling smtp.c)
 * ============================================================ */
#ifdef SMTP_INTERNAL_DEFINE

enum smtp_result_code {
  SMTP_INTERNAL_ERROR = -1,
  SMTP_READY        = 220,
  SMTP_AUTH_SUCCESS = 235,
  SMTP_DONE         = 250,
  SMTP_AUTH_CONTINUE = 334,
  SMTP_BEGIN_MAIL   = 354,
};

struct smtp_command {
  enum smtp_result_code code;
  int more;
  char *text;
};

enum str_getdelim_retcode {
  STRING_GETDELIMFD_ERROR,
  STRING_GETDELIMFD_NEXT,
  STRING_GETDELIMFD_DONE,
};

struct str_getdelimfd {
  char *_buf;
  size_t _bufsz;
  size_t _buf_len;
  char *line;
  size_t line_len;
  long (*getdelimfd_read)(struct str_getdelimfd *gdfd,
                          void *read_buf,
                          size_t read_buf_sz);
  void *user_data;
  int delim;
  char pad[4];
};

#endif /* SMTP_INTERNAL_DEFINE */

/* ============================================================
 * Public API
 * ============================================================ */

enum smtp_status_code
smtp_open(const char *const server,
          const char *const port,
          enum smtp_connection_security connection_security,
          enum smtp_flag flags,
          const char *const cafile,
          struct smtp **smtp);

enum smtp_status_code
smtp_auth(struct smtp *const smtp,
          enum smtp_authentication_method auth_method,
          const char *const user,
          const char *const pass);

enum smtp_status_code
smtp_mail(struct smtp *const smtp,
          const char *const body);

enum smtp_status_code
smtp_close(struct smtp *smtp);

enum smtp_status_code
smtp_status_code_get(const struct smtp *const smtp);

enum smtp_status_code
smtp_status_code_clear(struct smtp *const smtp);

enum smtp_status_code
smtp_status_code_set(struct smtp *const smtp,
                     enum smtp_status_code status_code);

const char *
smtp_status_code_errstr(enum smtp_status_code status_code);

enum smtp_status_code
smtp_header_add(struct smtp *const smtp,
                const char *const key,
                const char *const value);

void
smtp_header_clear_all(struct smtp *const smtp);

enum smtp_status_code
smtp_address_add(struct smtp *const smtp,
                 enum smtp_address_type type,
                 const char *const email,
                 const char *const name);

void
smtp_address_clear_all(struct smtp *const smtp);

enum smtp_status_code
smtp_attachment_add_path(struct smtp *const smtp,
                         const char *const name,
                         const char *const path);

enum smtp_status_code
smtp_attachment_add_fp(struct smtp *const smtp,
                       const char *const name,
                       FILE *fp);

enum smtp_status_code
smtp_attachment_add_mem(struct smtp *const smtp,
                        const char *const name,
                        const void *const data,
                        size_t datasz);

void
smtp_attachment_clear_all(struct smtp *const smtp);

#ifdef __cplusplus
}
#endif

#endif /* SMTP_H */
