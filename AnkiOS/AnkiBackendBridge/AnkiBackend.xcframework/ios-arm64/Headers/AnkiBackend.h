#ifndef ANKI_BACKEND_H
#define ANKI_BACKEND_H

typedef struct AnkiSyncBackend AnkiSyncBackend;

char *ankios_anki_extract_latex(const char *text, int svg, char **error_out);
char *ankios_anki_extract_latex_details(const char *text, int svg, int expand_clozes, char **error_out);
AnkiSyncBackend *ankios_anki_backend_open(const char *collection_path, const char *media_folder_path, const char *media_db_path, char **error_out);
char *ankios_anki_sync_login(AnkiSyncBackend *backend, const char *username, const char *password, const char *endpoint, char **error_out);
char *ankios_anki_sync_status(AnkiSyncBackend *backend, const char *hkey, const char *endpoint, char **error_out);
char *ankios_anki_sync_collection(AnkiSyncBackend *backend, const char *hkey, const char *endpoint, int sync_media, char **error_out);
char *ankios_anki_sync_full_upload_or_download(AnkiSyncBackend *backend, const char *hkey, const char *endpoint, int upload, int has_server_usn, int server_usn, char **error_out);
char *ankios_anki_sync_media(AnkiSyncBackend *backend, const char *hkey, const char *endpoint, char **error_out);
char *ankios_anki_media_sync_status(AnkiSyncBackend *backend, char **error_out);
char *ankios_anki_sync_abort(AnkiSyncBackend *backend, char **error_out);
char *ankios_anki_media_sync_abort(AnkiSyncBackend *backend, char **error_out);
char *ankios_anki_backend_close(AnkiSyncBackend *backend, char **error_out);
void ankios_anki_backend_destroy(AnkiSyncBackend *backend);
void ankios_anki_backend_free_string(char *value);
char *ankios_fsrs_compute_parameters(const char *input);
char *ankios_fsrs_simulate(const char *input);
void ankios_fsrs_free_string(char *value);

#endif
