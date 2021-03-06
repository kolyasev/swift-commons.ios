// ----------------------------------------------------------------------------
//
//  NSData.swift
//
//  @author     Alexander Bragin <alexander.bragin@gmail.com>
//  @copyright  Copyright (c) 2015, MediariuM Ltd. All rights reserved.
//  @link       http://www.mediarium.com/
//
// ----------------------------------------------------------------------------

import Foundation

// ----------------------------------------------------------------------------

public extension NSData
{
// MARK: - Properties

    var isEmpty: Bool {
        return (self.length < 1)
    }

// MARK: - Functions

    class func isNilOrEmpty(objects: NSData?...) -> Bool
    {
        if objects.isEmpty {
            return true
        }

        var result = false
        for obj in objects
        {
            if (obj == nil) || obj!.isEmpty
            {
                result = true
                break
            }
        }

        return result
    }

}

// ----------------------------------------------------------------------------
