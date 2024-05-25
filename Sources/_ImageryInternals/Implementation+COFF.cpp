//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for Swift project authors
//

#if defined(_WIN32)
#include "Image.h"
#include "Section.h"

#include <array>
#include <cstring>

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <Psapi.h>

static void setImageName(SMLImage *ioImage) {
  if (0 != GetModuleFileNameW(nullptr, ioImage->nameBuffer, std::size(ioImage->nameBuffer))) {
    ioImage->name = ioImage->nameBuffer;
  } else {
    ioImage->nameBuffer[0] = 0;
    ioImage->name = nullptr;
  }
}

// MARK: - Image

void sml_getMainImage(SMLImage *outImage) {
  outImage->base = GetModuleHandleW(nullptr);
  setImageName(outImage);
}

void sml_enumerateImages(void *_Null_unspecified context, SMLImageEnumerator body) {
  // Find all the modules loaded in the current process.
  std::array<HMODULE, 1024> hModules;
  DWORD byteCountNeeded = 0;
  if (!EnumProcessModules(GetCurrentProcess(), &hModules[0], hModules.size() * sizeof(HMODULE), &byteCountNeeded)) {
    return;
  }
  DWORD hModuleCount = std::min(hModules.size(), byteCountNeeded / sizeof(HMODULE));

  for (DWORD i = 0; i < hModuleCount; i++) {
    SMLImage image = { hModules[i] };
    setImageName(outImage);

    bool stop = false;
    body(context, &image, &stop);
    if (stop) {
      break;
    }
  }
}

bool sml_getImageContainingAddress(const void *address, SMLImage *outImage) {
  HMODULE hModule = nullptr;
  BOOL gotModule = GetModuleHandleExW(
    GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
    reinterpret_cast<LPCWSTR>(address),
    &hModule
  );
  if (gotModule && hModule) {
    outImage->base = hModule;
    setImageName(outImage);
    return true;
  }
  return false;
}

// MARK: - Section

bool sml_findSection(const SMLImage *image, const char *sectionName, SMLSection *outSection) {
  auto dosHeader = reinterpret_cast<const PIMAGE_DOS_HEADER>(const_cast<void *>(image->base));
  if (dosHeader->e_lfanew <= 0) {
    return false;
  }

  auto ntHeader = reinterpret_cast<const PIMAGE_NT_HEADERS>(reinterpret_cast<uintptr_t>(dosHeader) + dosHeader->e_lfanew);
  if (!ntHeader || ntHeader->Signature != IMAGE_NT_SIGNATURE) {
    return false;
  }

  auto sectionCount = ntHeader->FileHeader.NumberOfSections;
  auto section = IMAGE_FIRST_SECTION(ntHeader);
  for (size_t i = 0; i < sectionCount; i++, section += 1) {
    if (section->VirtualAddress == 0) {
      continue;
    }

    auto start = reinterpret_cast<const void *>(reinterpret_cast<uintptr_t>(dosHeader) + section->VirtualAddress);
    size_t size = std::min(section->Misc.VirtualSize, section->SizeOfRawData);
    if (start && size > 0) {
      // FIXME: Handle longer names ("/%u") from string table
      auto thisSectionName = reinterpret_cast<const char *>(section->Name);
      if (0 == std::strncmp(sectionName, thisSectionName, IMAGE_SIZEOF_SHORT_NAME)) {
        outSection->start = start;
        outSection->size = size;
        return true;
      }
    }
  }

  return false;
}

#endif
