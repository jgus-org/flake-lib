{ platformTags }:
{
  testBadPlatform = {
    expected = {
      success = false;
      value = false;
    };
    expr = builtins.tryEval (platformTags {
      platform = "x86_64 manylinux";
      pythonVersion = "3.13";
    });
  };
  testBadPythonVersion = {
    expected = {
      success = false;
      value = false;
    };
    expr = builtins.tryEval (platformTags {
      platform = "x86_64-linux";
      pythonVersion = "three";
    });
  };
  testBadVendor = {
    expected = {
      success = false;
      value = false;
    };
    expr = builtins.tryEval (platformTags {
      platform = "x86_64-windows";
      pythonVersion = "3.13";
    });
  };
  testDarwinAarch64 = {
    expected = {
      markerEnvironment = {
        implementation_name = "cpython";
        implementation_version = "3.14.0";
        os_name = "posix";
        platform_machine = "arm64";
        platform_python_implementation = "CPython";
        platform_release = "";
        platform_system = "Darwin";
        platform_version = "";
        python_full_version = "3.14.0";
        python_version = "3.14";
        sys_platform = "darwin";
      };
      pipAbi = "cp314";
      pipPlatforms = [ "macosx_14_0_arm64" ];
      pipPythonVersion = "314";
      python = "3.14";
      uvEnvironment.MACOSX_DEPLOYMENT_TARGET = "14.0";
      uvPythonPlatform = "aarch64-apple-darwin";
      uvPythonVersion = "3.14";
    };
    expr = platformTags {
      platform = "aarch64-apple-darwin";
      pythonVersion = "3.14";
    };
  };
  testDarwinX8664 = {
    expected = [ "macosx_14_0_x86_64" ];
    expr =
      (platformTags {
        platform = "x86_64-apple-darwin";
        pythonVersion = "3.13";
      }).pipPlatforms;
  };
  testManylinux = {
    expected = {
      markerEnvironment = {
        implementation_name = "cpython";
        implementation_version = "3.13.0";
        os_name = "posix";
        platform_machine = "x86_64";
        platform_python_implementation = "CPython";
        platform_release = "";
        platform_system = "Linux";
        platform_version = "";
        python_full_version = "3.13.0";
        python_version = "3.13";
        sys_platform = "linux";
      };
      pipAbi = "cp313";
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
      pipPythonVersion = "313";
      python = "3.13";
      uvEnvironment = { };
      uvPythonPlatform = "x86_64-manylinux_2_28";
      uvPythonVersion = "3.13";
    };
    expr = platformTags {
      platform = "x86_64-manylinux_2_28";
      pythonVersion = "3.13";
    };
  };
}
