#ifndef ANKI_FSRS_H
#define ANKI_FSRS_H

#include <stddef.h>

char *ankios_fsrs_compute_parameters(const char *input);
char *ankios_fsrs_simulate(const char *input);
void ankios_fsrs_free_string(char *value);

#endif
