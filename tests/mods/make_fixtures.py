#!/usr/bin/env python3
"""Fixtures for tests/mods/main.swift (ci/mods-tests.sh). The .7z is made by
ci/mods-tests.sh with 7zz; this writes the rest into the folder given."""
import os
import sys
import zipfile

out = sys.argv[1]
os.makedirs(out, exist_ok=True)

# A Windows-made zip: backslash names, plus an entry that tries to leave the folder.
with zipfile.ZipFile(os.path.join(out, "windows.zip"), "w") as z:
    z.writestr("My Mod\\Data\\textures\\sky.dds", "sky")
    z.writestr("../evil.txt", "evil")

with open(os.path.join(out, "broken.zip"), "wb") as f:
    f.write(b"PK\x03\x04" + b"\x00garbage" * 20)

mod = os.path.join(out, "fomod-mod", "Wrapper")


def put(rel, content):
    path = os.path.join(mod, *rel.split("/"))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)


put("core/Core.esp", "core")
put("optA/textures/b.dds", "A")
put("optB/textures/b.dds", "B")
put("extras/patch.esp", "patch")
put("cond/cond.txt", "cond")

config = """<?xml version="1.0" encoding="UTF-16"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://qconsulting.ca/fo3/ModConfig5.0.xsd">
  <moduleName>Test Installer</moduleName>
  <requiredInstallFiles>
    <folder source="core" destination="" />
  </requiredInstallFiles>
  <installSteps order="Explicit">
    <installStep name="Main">
      <optionalFileGroups order="Explicit">
        <group name="Texture" type="SelectExactlyOne">
          <plugins>
            <plugin name="B Option">
              <description>b</description>
              <files><folder source="optB" destination="" priority="1" /></files>
              <conditionFlags><flag name="tex">B</flag></conditionFlags>
              <typeDescriptor><type name="Recommended" /></typeDescriptor>
            </plugin>
            <plugin name="A Option">
              <description>a</description>
              <files><folder source="optA" destination="" priority="0" /></files>
              <conditionFlags><flag name="tex">A</flag></conditionFlags>
              <typeDescriptor><type name="Optional" /></typeDescriptor>
            </plugin>
          </plugins>
        </group>
      </optionalFileGroups>
    </installStep>
    <installStep name="Extras">
      <visible><flagDependency flag="tex" value="B" /></visible>
      <optionalFileGroups>
        <group name="Patches" type="SelectAny">
          <plugins>
            <plugin name="Patch">
              <description>p</description>
              <files><file source="extras\\patch.esp" destination="Patches\\patch.esp" /></files>
              <typeDescriptor><type name="Optional" /></typeDescriptor>
            </plugin>
          </plugins>
        </group>
      </optionalFileGroups>
    </installStep>
    <installStep name="Hidden">
      <visible><fileDependency file="Missing.esp" state="Active" /></visible>
      <optionalFileGroups>
        <group name="G" type="SelectAll">
          <plugins>
            <plugin name="X"><description /><typeDescriptor><type name="Required" /></typeDescriptor></plugin>
          </plugins>
        </group>
      </optionalFileGroups>
    </installStep>
  </installSteps>
  <conditionalFileInstalls>
    <patterns>
      <pattern>
        <dependencies operator="And">
          <flagDependency flag="tex" value="B" />
          <fileDependency file="Skyrim.esm" state="Active" />
        </dependencies>
        <files><folder source="cond" destination="" /></files>
      </pattern>
    </patterns>
  </conditionalFileInstalls>
</config>
"""
os.makedirs(os.path.join(mod, "fomod"), exist_ok=True)
with open(os.path.join(mod, "fomod", "ModuleConfig.xml"), "wb") as f:
    f.write(b"\xff\xfe" + config.encode("utf-16-le"))
