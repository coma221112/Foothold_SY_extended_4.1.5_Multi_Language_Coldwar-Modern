call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
cd /d "C:\Users\Drac\Saved Games\DCS\Missions\Foothold_SY_extended_4.1.5_Multi_Language_Coldwar-Modern\native\llmbridge"
cl /nologo /std:c++17 /EHsc /O2 /MT /LD llmbridge.cpp /link /NOLOGO /OUT:"C:\Users\Drac\Saved Games\DCS\Missions\Foothold_SY_extended_4.1.5_Multi_Language_Coldwar-Modern\native\llmbridge\build\llmbridge.dll" winhttp.lib
