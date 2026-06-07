//
//  CLIOut.swift
//  SMCFan
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-01-18.
//  Copyright © 2026, all rights reserved.
//
//  User-facing stdout/stderr writes per Rule 5.
//  Diagnostic output goes to os.Logger, not here.
//

import Foundation

enum CLIOut {
  static func print(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
  }

  static func err(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
  }
}
