#include "NSOUSB.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdlib.h>

struct NSOUSBConnection {
  IOUSBInterfaceInterface **interface;
  UInt8 outputPipe;
};

static Boolean readUInt32Property(io_service_t service, CFStringRef key,
                                  UInt32 *result) {
  CFTypeRef value =
      IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
  if (!value)
    return false;
  Boolean valid =
      CFGetTypeID(value) == CFNumberGetTypeID() &&
      CFNumberGetValue((CFNumberRef)value, kCFNumberSInt32Type, result);
  CFRelease(value);
  return valid;
}

static NSOUSBConnection *failOpen(NSOUSBConnection *connection, int error,
                                  int *errorOut) {
  if (connection)
    free(connection);
  if (errorOut)
    *errorOut = error;
  return NULL;
}

NSOUSBConnection *NSOUSBOpen(uint16_t vendorID, uint16_t productID,
                             uint8_t interfaceNumber, uint32_t locationID,
                             int *errorOut) {
  if (errorOut)
    *errorOut = 0;
  NSOUSBConnection *connection = calloc(1, sizeof(*connection));
  if (!connection)
    return failOpen(NULL, -8, errorOut);
  // Modern macOS exposes this composite controller as IOUSBHostInterface,
  // not the older IOUSBInterface class used by pre-USB-C Macs.
  CFMutableDictionaryRef matching =
      IOServiceMatching(kIOUSBHostInterfaceClassName);
  if (!matching)
    return failOpen(connection, -1, errorOut);

  UInt32 vid = vendorID, pid = productID, ifnum = interfaceNumber;
  io_iterator_t iterator = 0;
  if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) !=
      KERN_SUCCESS)
    return failOpen(connection, -2, errorOut);
  // Match properties manually. On recent macOS versions the host-family
  // matching dictionary can omit composite-interface children even though
  // they are visible in the IORegistry.
  io_service_t service = 0, candidate = 0;
  while ((service = IOIteratorNext(iterator))) {
    UInt32 foundVendor = 0, foundProduct = 0, foundInterface = 0;
    UInt32 foundLocation = 0;
    Boolean hasVendor =
        readUInt32Property(service, CFSTR(kUSBVendorID), &foundVendor);
    Boolean hasProduct =
        readUInt32Property(service, CFSTR(kUSBProductID), &foundProduct);
    Boolean hasInterface = readUInt32Property(
        service, CFSTR(kUSBInterfaceNumber), &foundInterface);
    Boolean hasLocation = readUInt32Property(
        service, CFSTR(kUSBDevicePropertyLocationID), &foundLocation);
    if (hasVendor && hasProduct && hasInterface && foundVendor == vid &&
        foundProduct == pid && foundInterface == ifnum &&
        (!locationID || (hasLocation && foundLocation == locationID))) {
      candidate = service;
      break;
    }
    IOObjectRelease(service);
  }
  service = candidate;
  IOObjectRelease(iterator);
  if (!service)
    return failOpen(connection, -3, errorOut);

  IOCFPlugInInterface **plugin = NULL;
  SInt32 score = 0;
  IOReturn result = IOCreatePlugInInterfaceForService(
      service, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin,
      &score);
  IOObjectRelease(service);
  if (result != kIOReturnSuccess || !plugin)
    return failOpen(connection, -4, errorOut);

  HRESULT query = (*plugin)->QueryInterface(
      plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID),
      (LPVOID *)&connection->interface);
  (*plugin)->Release(plugin);
  if (query != S_OK || !connection->interface)
    return failOpen(connection, -5, errorOut);

  result = (*connection->interface)->USBInterfaceOpen(connection->interface);
  if (result != kIOReturnSuccess) {
    // Interface 1 can be claimed by the system HID stack. The Python
    // bridge detached that interface before opening the bulk endpoint;
    // OpenSeize is the IOKit equivalent.
    result =
        (*connection->interface)->USBInterfaceOpenSeize(connection->interface);
  }
  if (result != kIOReturnSuccess) {
    (*connection->interface)->Release(connection->interface);
    connection->interface = NULL;
    // IOReturn already carries a stable signed error value. Negating it can
    // overflow into a large positive number and makes diagnostics useless.
    return failOpen(connection, (int)result, errorOut);
  }

  UInt8 endpointCount = 0;
  if ((*connection->interface)
          ->GetNumEndpoints(connection->interface, &endpointCount) !=
      kIOReturnSuccess) {
    (*connection->interface)->USBInterfaceClose(connection->interface);
    (*connection->interface)->Release(connection->interface);
    connection->interface = NULL;
    return failOpen(connection, -6, errorOut);
  }
  for (UInt8 pipe = 1; pipe <= endpointCount; pipe++) {
    UInt8 direction = 0, number = 0, type = 0, interval = 0;
    UInt16 maxPacket = 0;
    if ((*connection->interface)
                ->GetPipeProperties(connection->interface, pipe, &direction,
                                    &number, &type, &maxPacket,
                                    &interval) == kIOReturnSuccess &&
        direction == kUSBOut && type == kUSBBulk) {
      connection->outputPipe = pipe;
      return connection;
    }
  }
  (*connection->interface)->USBInterfaceClose(connection->interface);
  (*connection->interface)->Release(connection->interface);
  connection->interface = NULL;
  return failOpen(connection, -7, errorOut);
}

int NSOUSBWrite(NSOUSBConnection *connection, const uint8_t *bytes,
                uint32_t length) {
  if (!connection || !connection->interface || !connection->outputPipe ||
      !bytes || !length || length > 1024)
    return 0;
  return (*connection->interface)
             ->WritePipe(connection->interface, connection->outputPipe,
                         (void *)bytes, length) == kIOReturnSuccess;
}

void NSOUSBClose(NSOUSBConnection *connection) {
  if (!connection)
    return;
  if (connection->interface) {
    (*connection->interface)->USBInterfaceClose(connection->interface);
    (*connection->interface)->Release(connection->interface);
  }
  free(connection);
}
