call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
cd /d "C:\Users\CodexSandboxOffline\.codex\.sandbox\cwd\ebc5119163725e55\native\llmbridge"
cl /nologo /std:c++17 /EHsc /O2 /MT /LD llmbridge.cpp /link /NOLOGO /OUT:"C:\Users\CodexSandboxOffline\.codex\.sandbox\cwd\ebc5119163725e55\native\llmbridge\build\llmbridge.dll" winhttp.lib
