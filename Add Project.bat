@echo off
title Jedit.Jed - Add Project
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\add-project.ps1" %*
