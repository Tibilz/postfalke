#ifndef PGPCORE_H
#define PGPCORE_H

/// Runs one JSON request, returns a JSON response. Free the result with pgpcore_free.
char *pgpcore_call(const char *request);
void pgpcore_free(char *ptr);

#endif
