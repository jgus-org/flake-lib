{ platformTags }:
{
  manylinux = {
    expr = platformTags { pythonVersion = "3.13"; platform = "x86_64-manylinux_2_28"; };
    expected = {
      uvPythonVersion = "3.13";
      uvPythonPlatform = "x86_64-manylinux_2_28";
      pipPythonVersion = "313";
      pipPlatform = "manylinux_2_28_x86_64";
      pipAbi = "cp313";
    };
  };
  plain-linux = {
    expr = platformTags { pythonVersion = "3.12"; platform = "x86_64-linux"; };
    expected = {
      uvPythonVersion = "3.12";
      uvPythonPlatform = "x86_64-linux";
      pipPythonVersion = "312";
      pipPlatform = "linux_x86_64";
      pipAbi = "cp312";
    };
  };
  aarch64 = {
    expr = platformTags { pythonVersion = "3.14"; platform = "aarch64-manylinux_2_39"; };
    expected = {
      uvPythonVersion = "3.14";
      uvPythonPlatform = "aarch64-manylinux_2_39";
      pipPythonVersion = "314";
      pipPlatform = "manylinux_2_39_aarch64";
      pipAbi = "cp314";
    };
  };
  bad-python-version = {
    expr = builtins.tryEval (platformTags { pythonVersion = "three"; platform = "x86_64-linux"; });
    expected = { success = false; value = false; };
  };
  bad-platform = {
    expr = builtins.tryEval (platformTags { pythonVersion = "3.13"; platform = "x86_64 manylinux"; });
    expected = { success = false; value = false; };
  };
}
