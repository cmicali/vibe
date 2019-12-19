//
//  Util.h
//  Vibe
//
//  Created by Christopher Micali on 12/14/19.
//  Copyright © 2019 Christopher Micali. All rights reserved.
//

#pragma once

template<typename Base, typename T>
inline bool instanceof(const T *ptr) {
    return dynamic_cast<const Base*>(ptr) != nullptr;
}

