/* Minimal UEFI definitions: only what ClaraOS touches during the boot handoff.
 * Layouts follow the UEFI 2.10 specification. Table slots we never call are
 * kept as void * so the offsets of the members we do call stay correct. */
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef uint64_t UINTN;
typedef uint64_t EFI_STATUS;
typedef void    *EFI_HANDLE;
typedef uint16_t CHAR16;
typedef uint8_t  BOOLEAN;
typedef uint64_t EFI_PHYSICAL_ADDRESS;
typedef uint64_t EFI_VIRTUAL_ADDRESS;

#define EFI_SUCCESS           0ULL
#define EFI_ERROR_BIT         0x8000000000000000ULL
#define EFI_INVALID_PARAMETER (EFI_ERROR_BIT | 2)
#define EFI_BUFFER_TOO_SMALL  (EFI_ERROR_BIT | 5)
#define EFI_OUT_OF_RESOURCES  (EFI_ERROR_BIT | 9)
#define EFI_NOT_FOUND         (EFI_ERROR_BIT | 14)
#define EFI_ERROR(s)          (((EFI_STATUS)(s) & EFI_ERROR_BIT) != 0)

typedef struct {
    uint32_t Data1;
    uint16_t Data2;
    uint16_t Data3;
    uint8_t  Data4[8];
} EFI_GUID;

typedef struct {
    uint64_t Signature;
    uint32_t Revision;
    uint32_t HeaderSize;
    uint32_t CRC32;
    uint32_t Reserved;
} EFI_TABLE_HEADER;

enum efi_memory_type {
    EfiReservedMemoryType, EfiLoaderCode, EfiLoaderData,
    EfiBootServicesCode, EfiBootServicesData,
    EfiRuntimeServicesCode, EfiRuntimeServicesData,
    EfiConventionalMemory, EfiUnusableMemory,
    EfiACPIReclaimMemory, EfiACPIMemoryNVS,
    EfiMemoryMappedIO, EfiMemoryMappedIOPortSpace,
    EfiPalCode, EfiPersistentMemory, EfiMaxMemoryType
};

typedef struct {
    uint32_t             Type;          /* 4 bytes of padding follow */
    EFI_PHYSICAL_ADDRESS PhysicalStart;
    EFI_VIRTUAL_ADDRESS  VirtualStart;
    uint64_t             NumberOfPages; /* 4 KiB pages */
    uint64_t             Attribute;
} EFI_MEMORY_DESCRIPTOR;

/* Descriptors in a memory map are desc_size bytes apart, which can be more
 * than the structure above. */
static inline const EFI_MEMORY_DESCRIPTOR *efi_region(const void *map, uint64_t desc_size, uint64_t i)
{
    return (const void *)((const uint8_t *)map + i * desc_size);
}

/* Is this kind of region ordinary memory, whoever is using it? The map also
 * lists device and reserved address space, which can lie far above RAM. */
static inline int efi_is_ram(uint32_t type)
{
    switch (type) {
    case EfiLoaderCode:
    case EfiLoaderData:
    case EfiBootServicesCode:
    case EfiBootServicesData:
    case EfiRuntimeServicesCode:
    case EfiRuntimeServicesData:
    case EfiConventionalMemory:
    case EfiACPIReclaimMemory:
    case EfiACPIMemoryNVS:
        return 1;
    default:
        return 0;
    }
}

enum efi_allocate_type { AllocateAnyPages, AllocateMaxAddress, AllocateAddress };

typedef struct EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL;
struct EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL {
    void *Reset;
    EFI_STATUS (*OutputString)(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *self, const CHAR16 *s);
    void *TestString, *QueryMode, *SetMode, *SetAttribute;
    EFI_STATUS (*ClearScreen)(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *self);
    void *SetCursorPosition, *EnableCursor, *Mode;
};

typedef struct {
    EFI_TABLE_HEADER Hdr;
    void *RaiseTPL, *RestoreTPL;
    EFI_STATUS (*AllocatePages)(uint32_t allocate_type, uint32_t memory_type, UINTN pages,
                                EFI_PHYSICAL_ADDRESS *memory);
    void *FreePages;
    EFI_STATUS (*GetMemoryMap)(UINTN *size, EFI_MEMORY_DESCRIPTOR *map, UINTN *key,
                               UINTN *desc_size, uint32_t *desc_version);
    void *AllocatePool, *FreePool;
    void *CreateEvent, *SetTimer, *WaitForEvent, *SignalEvent, *CloseEvent, *CheckEvent;
    void *InstallProtocolInterface, *ReinstallProtocolInterface, *UninstallProtocolInterface;
    EFI_STATUS (*HandleProtocol)(EFI_HANDLE handle, const EFI_GUID *protocol, void **interface);
    void *Reserved, *RegisterProtocolNotify, *LocateHandle, *LocateDevicePath;
    void *InstallConfigurationTable;
    void *LoadImage, *StartImage, *Exit, *UnloadImage;
    EFI_STATUS (*ExitBootServices)(EFI_HANDLE image, UINTN map_key);
    void *GetNextMonotonicCount, *Stall, *SetWatchdogTimer;
    void *ConnectController, *DisconnectController;
    void *OpenProtocol, *CloseProtocol, *OpenProtocolInformation;
    void *ProtocolsPerHandle, *LocateHandleBuffer;
    EFI_STATUS (*LocateProtocol)(const EFI_GUID *protocol, void *registration, void **interface);
    void *InstallMultipleProtocolInterfaces, *UninstallMultipleProtocolInterfaces;
    void *CalculateCrc32;
    void *CopyMem, *SetMem, *CreateEventEx;
} EFI_BOOT_SERVICES;

typedef struct {
    EFI_GUID VendorGuid;
    void    *VendorTable;
} EFI_CONFIGURATION_TABLE;

typedef struct {
    EFI_TABLE_HEADER                 Hdr;
    CHAR16                          *FirmwareVendor;
    uint32_t                         FirmwareRevision;
    EFI_HANDLE                       ConsoleInHandle;
    void                            *ConIn;
    EFI_HANDLE                       ConsoleOutHandle;
    EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *ConOut;
    EFI_HANDLE                       StandardErrorHandle;
    EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *StdErr;
    void                            *RuntimeServices;
    EFI_BOOT_SERVICES               *BootServices;
    UINTN                            NumberOfTableEntries;
    EFI_CONFIGURATION_TABLE         *ConfigurationTable;
} EFI_SYSTEM_TABLE;

/* Loaded Image Protocol: where this image came from */
typedef struct {
    uint32_t          Revision;        /* 4 bytes of padding follow */
    EFI_HANDLE        ParentHandle;
    EFI_SYSTEM_TABLE *SystemTable;
    EFI_HANDLE        DeviceHandle;    /* the volume the image was read from */
    void             *FilePath;
    void             *Reserved;
    uint32_t          LoadOptionsSize; /* 4 bytes of padding follow */
    void             *LoadOptions;
    void             *ImageBase;
    uint64_t          ImageSize;
    uint32_t          ImageCodeType, ImageDataType;
    void             *Unload;
} EFI_LOADED_IMAGE_PROTOCOL;

/* Simple File System Protocol and File Protocol */
typedef struct EFI_FILE_PROTOCOL EFI_FILE_PROTOCOL;
struct EFI_FILE_PROTOCOL {
    uint64_t Revision;
    EFI_STATUS (*Open)(EFI_FILE_PROTOCOL *self, EFI_FILE_PROTOCOL **file, const CHAR16 *name,
                       uint64_t mode, uint64_t attributes);
    EFI_STATUS (*Close)(EFI_FILE_PROTOCOL *self);
    void *Delete;
    /* On a directory, Read returns one EFI_FILE_INFO per call and a size of 0 at the end. */
    EFI_STATUS (*Read)(EFI_FILE_PROTOCOL *self, UINTN *size, void *buffer);
    void *Write, *GetPosition, *SetPosition, *GetInfo, *SetInfo, *Flush;
};

typedef struct EFI_SIMPLE_FILE_SYSTEM_PROTOCOL EFI_SIMPLE_FILE_SYSTEM_PROTOCOL;
struct EFI_SIMPLE_FILE_SYSTEM_PROTOCOL {
    uint64_t Revision;
    EFI_STATUS (*OpenVolume)(EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *self, EFI_FILE_PROTOCOL **root);
};

typedef struct {
    uint64_t Size;                 /* of this structure, the name included */
    uint64_t FileSize;             /* in bytes */
    uint64_t PhysicalSize;
    uint8_t  CreateTime[16], LastAccessTime[16], ModificationTime[16]; /* EFI_TIME */
    uint64_t Attribute;
    CHAR16   FileName[];           /* null-terminated */
} EFI_FILE_INFO;

#define EFI_FILE_MODE_READ 0x1ULL
#define EFI_FILE_DIRECTORY 0x10ULL  /* an Attribute bit */

/* Graphics Output Protocol */
enum efi_pixel_format {
    PixelRedGreenBlueReserved8BitPerColor,
    PixelBlueGreenRedReserved8BitPerColor,
    PixelBitMask,
    PixelBltOnly
};

typedef struct {
    uint32_t Version;
    uint32_t HorizontalResolution;
    uint32_t VerticalResolution;
    uint32_t PixelFormat;
    uint32_t RedMask, GreenMask, BlueMask, ReservedMask;
    uint32_t PixelsPerScanLine;
} EFI_GRAPHICS_OUTPUT_MODE_INFORMATION;

typedef struct {
    uint32_t                              MaxMode;
    uint32_t                              Mode;
    EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *Info;
    UINTN                                 SizeOfInfo;
    EFI_PHYSICAL_ADDRESS                  FrameBufferBase;
    UINTN                                 FrameBufferSize;
} EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE;

typedef struct {
    void *QueryMode, *SetMode, *Blt;
    EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE *Mode;
} EFI_GRAPHICS_OUTPUT_PROTOCOL;

#define EFI_LOADED_IMAGE_PROTOCOL_GUID \
    { 0x5b1b31a1, 0x9562, 0x11d2, { 0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b } }
#define EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID \
    { 0x964e5b22, 0x6459, 0x11d2, { 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b } }
#define EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID \
    { 0x9042a9de, 0x23dc, 0x4a38, { 0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a } }
#define EFI_ACPI_20_TABLE_GUID \
    { 0x8868e871, 0xe4f1, 0x11d3, { 0xbc, 0x22, 0x00, 0x80, 0xc7, 0x3c, 0x88, 0x81 } }
#define EFI_DTB_TABLE_GUID \
    { 0xb1b621d5, 0xf19c, 0x41a5, { 0x83, 0x0b, 0xd9, 0x15, 0x2c, 0x69, 0xaa, 0xe0 } }
