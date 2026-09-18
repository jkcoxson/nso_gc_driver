#include "../Sources/NSOGCDriver/NSOUSB.h"
#include <stdio.h>

int main(void) {
  int result = 0;
  NSOUSBConnection *connection = NSOUSBOpen(0x057e, 0x2073, 1, 0, &result);
  printf("NSOUSBOpen result: %d\n", connection ? 1 : result);
  if (connection)
    NSOUSBClose(connection);
  return connection ? 0 : 1;
}
