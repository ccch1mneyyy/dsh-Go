@rem Copyright (c) Huawei Technologies Co., Ltd. 2020-2030. All rights reserved.
@echo off
setlocal DisableDelayedExpansion
"%~dp0..\..\tool\node\node.exe" "%~dp0pm-cli.js" %*
exit /b %ERRORLEVEL%
