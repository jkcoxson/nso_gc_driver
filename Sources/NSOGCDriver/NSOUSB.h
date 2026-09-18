#ifndef NSOUSB_H
#define NSOUSB_H

#include <stdint.h>

typedef struct NSOUSBConnection NSOUSBConnection;

// Opens the command interface belonging to the device at locationID. A zero
// location ID accepts the first match. Returns NULL on failure and writes a
// negative stage/error code to errorOut when it is non-NULL.
NSOUSBConnection *NSOUSBOpen(uint16_t vendorID, uint16_t productID,
                             uint8_t interfaceNumber, uint32_t locationID,
                             int *errorOut);
int NSOUSBWrite(NSOUSBConnection *connection, const uint8_t *bytes,
                uint32_t length);
void NSOUSBClose(NSOUSBConnection *connection);

#endif
