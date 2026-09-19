{ platformTags }:
{
  testManylinux = {
    expr = platformTags { pythonVersion = "3.13"; platform = "x86_64-manylinux_2_28"; };
    expected = {
      python = "3.13";
      uvPythonVersion = "3.13";
      uvPythonPlatform = "x86_64-manylinux_2_28";
      pipPythonVersion = "313";
      pipPlatforms = [
        "manylinux_2_28_x86_64"
        "manylinux_2_27_x86_64"
        "manylinux_2_26_x86_64"
        "manylinux_2_25_x86_64"
        "manylinux_2_24_x86_64"
        "manylinux_2_23_x86_64"
        "manylinux_2_22_x86_64"
        "manylinux_2_21_x86_64"
        "manylinux_2_20_x86_64"
        "manylinux_2_19_x86_64"
        "manylinux_2_18_x86_64"
        "manylinux_2_17_x86_64"
        "manylinux_2_16_x86_64"
        "manylinux_2_15_x86_64"
        "manylinux_2_14_x86_64"
        "manylinux_2_13_x86_64"
        "manylinux_2_12_x86_64"
        "manylinux_2_11_x86_64"
        "manylinux_2_10_x86_64"
        "manylinux_2_9_x86_64"
        "manylinux_2_8_x86_64"
        "manylinux_2_7_x86_64"
        "manylinux_2_6_x86_64"
        "manylinux_2_5_x86_64"
        "manylinux2014_x86_64"
        "manylinux2010_x86_64"
        "manylinux1_x86_64"
        "linux_x86_64"
      ];
      pipAbi = "cp313";
    };
  };
  testManylinuxAarch64 = {
    expr = platformTags { pythonVersion = "3.12"; platform = "aarch64-manylinux_2_17"; };
    expected = {
      python = "3.12";
      uvPythonVersion = "3.12";
      uvPythonPlatform = "aarch64-manylinux_2_17";
      pipPythonVersion = "312";
      pipPlatforms = [
        "manylinux_2_17_aarch64"
        "manylinux_2_16_aarch64"
        "manylinux_2_15_aarch64"
        "manylinux_2_14_aarch64"
        "manylinux_2_13_aarch64"
        "manylinux_2_12_aarch64"
        "manylinux_2_11_aarch64"
        "manylinux_2_10_aarch64"
        "manylinux_2_9_aarch64"
        "manylinux_2_8_aarch64"
        "manylinux_2_7_aarch64"
        "manylinux_2_6_aarch64"
        "manylinux_2_5_aarch64"
        "manylinux2014_aarch64"
        "linux_aarch64"
      ];
      pipAbi = "cp312";
    };
  };
  testPlainLinux = {
    expr = platformTags { pythonVersion = "3.12"; platform = "x86_64-linux"; };
    expected = {
      python = "3.12";
      uvPythonVersion = "3.12";
      uvPythonPlatform = "x86_64-linux";
      pipPythonVersion = "312";
      pipPlatforms = [ "linux_x86_64" ];
      pipAbi = "cp312";
    };
  };
  testBadPythonVersion = {
    expr = builtins.tryEval (platformTags { pythonVersion = "three"; platform = "x86_64-linux"; });
    expected = { success = false; value = false; };
  };
  testBadPlatform = {
    expr = builtins.tryEval (platformTags { pythonVersion = "3.13"; platform = "x86_64 manylinux"; });
    expected = { success = false; value = false; };
  };
  testBadVendor = {
    expr = builtins.tryEval (platformTags { pythonVersion = "3.13"; platform = "x86_64-darwin"; });
    expected = { success = false; value = false; };
  };
}
